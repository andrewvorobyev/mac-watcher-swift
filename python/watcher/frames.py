"""Frame capture helpers for Gemini realtime streaming."""

from __future__ import annotations

import asyncio
import base64
import enum
import logging
from dataclasses import dataclass
from types import TracebackType
from typing import AsyncIterator, Literal, TypedDict

import cv2
import mss
import numpy as np
import numpy.typing as npt

LOGGER = logging.getLogger(__name__)


FrameArray = npt.NDArray[np.uint8]


class FramePayload(TypedDict):
    """Structure representing a base64-encoded frame accepted by Gemini."""

    mime_type: Literal["image/jpeg"]
    data: str


class CaptureMode(enum.StrEnum):
    """Supported frame capture types."""

    CAMERA = "camera"
    SCREEN = "screen"


def encode_frame(
    frame: FrameArray,
    *,
    max_dimension: int,
    jpeg_quality: int,
) -> FramePayload:
    """Convert an OpenCV frame to a JPEG payload the API understands."""

    if frame.ndim != 3:
        msg = "Frame must have three dimensions (H, W, C)."
        raise ValueError(msg)

    if frame.shape[2] not in (3, 4):
        msg = "Frame must contain 3 (BGR) or 4 (BGRA) channels."
        raise ValueError(msg)

    working = frame[:, :, :3]

    height, width = working.shape[:2]
    largest_edge = max(height, width)
    if largest_edge > max_dimension:
        scale = max_dimension / float(largest_edge)
        new_size = (int(width * scale), int(height * scale))
        working = cv2.resize(working, new_size, interpolation=cv2.INTER_AREA)

    success, buffer = cv2.imencode(
        ".jpg", working, [int(cv2.IMWRITE_JPEG_QUALITY), int(jpeg_quality)]
    )
    if not success:
        msg = "OpenCV failed to encode the frame to JPEG."
        raise RuntimeError(msg)

    encoded = base64.b64encode(buffer).decode("ascii")
    return FramePayload(mime_type="image/jpeg", data=encoded)


class FrameSource:
    """Base class handling throttling and encoding for frame publishers."""

    def __init__(
        self,
        *,
        fps: float,
        max_dimension: int,
        jpeg_quality: int,
    ) -> None:
        if fps <= 0:
            msg = "Frames per second must be a positive value."
            raise ValueError(msg)
        if max_dimension <= 0:
            msg = "Maximum dimension must be positive."
            raise ValueError(msg)
        if not 1 <= jpeg_quality <= 100:
            msg = "JPEG quality must be between 1 and 100."
            raise ValueError(msg)

        self._fps = fps
        self._frame_interval = 1.0 / fps
        self._max_dimension = max_dimension
        self._jpeg_quality = jpeg_quality

    async def __aenter__(self) -> FrameSource:
        await self._open()
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        await self._close()

    async def frames(self) -> AsyncIterator[FramePayload]:
        while True:
            frame = await self._read()
            if frame is None:
                LOGGER.debug("Frame source returned None; stopping capture loop.")
                break

            payload = await asyncio.to_thread(
                encode_frame,
                frame,
                max_dimension=self._max_dimension,
                jpeg_quality=self._jpeg_quality,
            )
            yield payload
            await asyncio.sleep(self._frame_interval)

    async def _open(self) -> None:
        raise NotImplementedError

    async def _close(self) -> None:
        raise NotImplementedError

    async def _read(self) -> FrameArray | None:
        raise NotImplementedError


class CameraFrameSource(FrameSource):
    """Capture frames from a webcam using OpenCV."""

    def __init__(
        self,
        *,
        camera_index: int,
        fps: float,
        max_dimension: int,
        jpeg_quality: int,
    ) -> None:
        super().__init__(
            fps=fps,
            max_dimension=max_dimension,
            jpeg_quality=jpeg_quality,
        )
        self._camera_index = camera_index
        self._capture: cv2.VideoCapture | None = None

    async def _open(self) -> None:
        capture = await asyncio.to_thread(cv2.VideoCapture, self._camera_index)
        if not capture.isOpened():
            await asyncio.to_thread(capture.release)
            msg = f"Unable to open camera at index {self._camera_index}."
            raise RuntimeError(msg)

        self._capture = capture

    async def _close(self) -> None:
        if self._capture is not None:
            await asyncio.to_thread(self._capture.release)
            self._capture = None

    async def _read(self) -> FrameArray | None:
        if self._capture is None:
            msg = "Camera capture attempted before initialization."
            raise RuntimeError(msg)

        ret, frame = await asyncio.to_thread(self._capture.read)
        if not ret:
            LOGGER.warning("Camera returned no frame; ending stream.")
            return None
        return frame  # type: ignore


class ScreenFrameSource(FrameSource):
    """Capture frames from the desktop using MSS."""

    def __init__(
        self,
        *,
        monitor_index: int,
        fps: float,
        max_dimension: int,
        jpeg_quality: int,
    ) -> None:
        super().__init__(
            fps=fps,
            max_dimension=max_dimension,
            jpeg_quality=jpeg_quality,
        )
        self._monitor_index = monitor_index
        self._sct: mss.base.MSSBase | None = None
        self._monitor: dict[str, int] | None = None

    async def _open(self) -> None:
        sct = await asyncio.to_thread(mss.mss)
        monitors = sct.monitors
        if not (0 <= self._monitor_index < len(monitors)):
            await asyncio.to_thread(sct.close)
            msg = f"Monitor index {self._monitor_index} is out of range."
            raise ValueError(msg)

        self._sct = sct
        self._monitor = monitors[self._monitor_index]

    async def _close(self) -> None:
        if self._sct is not None:
            await asyncio.to_thread(self._sct.close)
            self._sct = None
            self._monitor = None

    async def _read(self) -> FrameArray | None:
        if self._sct is None or self._monitor is None:
            msg = "Screen capture attempted before initialization."
            raise RuntimeError(msg)

        shot = await asyncio.to_thread(self._sct.grab, self._monitor)
        frame = np.array(shot)[:, :, :3]
        return frame


@dataclass(frozen=True)
class FrameSourceSpec:
    """Container describing how to instantiate a frame source."""

    mode: CaptureMode
    fps: float
    max_dimension: int
    jpeg_quality: int
    camera_index: int
    monitor_index: int


def create_frame_source(spec: FrameSourceSpec) -> FrameSource:
    """Factory producing a concrete frame source based on the provided spec."""

    if spec.mode is CaptureMode.CAMERA:
        return CameraFrameSource(
            camera_index=spec.camera_index,
            fps=spec.fps,
            max_dimension=spec.max_dimension,
            jpeg_quality=spec.jpeg_quality,
        )

    if spec.mode is CaptureMode.SCREEN:
        return ScreenFrameSource(
            monitor_index=spec.monitor_index,
            fps=spec.fps,
            max_dimension=spec.max_dimension,
            jpeg_quality=spec.jpeg_quality,
        )

    msg = f"Unsupported capture mode: {spec.mode}"
    raise ValueError(msg)


__all__ = [
    "CaptureMode",
    "FramePayload",
    "FrameSource",
    "FrameSourceSpec",
    "create_frame_source",
]
