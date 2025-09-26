"""Gemini realtime streaming orchestration."""

import asyncio
import base64
import logging
import time
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from google import genai
from google.genai.types import LiveConnectConfigDict

from watcher.frames import FramePayload, FrameSource
from watcher.live_session import LiveSession

from typing import Protocol

LOGGER = logging.getLogger(__name__)


class Streamer(Protocol):
    async def stream(self, source: FrameSource) -> None:
        ...


@dataclass(frozen=True)
class RealtimeStreamer(Streamer):
    model: str
    instructions: str | None = None

    async def stream(self, source: FrameSource) -> None:
        ...


class LiveApiMode(StrEnum):
    REALTIME = "REALTIME"
    SEQUENTIAL = "SEQUENTIAL"


@dataclass(slots=True)
class StreamerOptions:
    """Control how the realtime session behaves."""

    model: str
    config: LiveConnectConfigDict
    initial_text: str | None = None
    frame_dump_dir: Path | None = None
    api_mode: LiveApiMode = LiveApiMode.REALTIME

    def __post_init__(self) -> None:
        if isinstance(self.frame_dump_dir, str):
            self.frame_dump_dir = Path(self.frame_dump_dir)


class GeminiRealtimeStreamer:
    """Send frames from a source to Gemini Realtime and surface responses."""

    def __init__(self, *, client: genai.Client, options: StreamerOptions) -> None:
        self._client = client
        self._options = options

    async def stream(self, source: FrameSource) -> None:
        async with source:
            async with self._client.aio.live.connect(
                model=self._options.model,
                config=self._options.config,
            ) as session:
                if self._options.initial_text:
                    await session.send(
                        input=self._options.initial_text, end_of_turn=True
                    )

                async with asyncio.TaskGroup() as group:
                    group.create_task(self._forward_frames(session, source))
                    group.create_task(self._consume_responses(session))

    async def _forward_frames(self, session: LiveSession, source: FrameSource) -> None:
        try:
            async for payload in source.frames():
                if self._options.frame_dump_dir is not None:
                    await asyncio.to_thread(self._dump_frame, payload)

                match self._options.api_mode:
                    case LiveApiMode.REALTIME:
                        await session.send_realtime_input(media=payload)
                        LOGGER.info("realtime input sent")
                    case LiveApiMode.SEQUENTIAL:
                        LOGGER.info("sequential input sent")
                        turns = [{"role": "user", "parts": [{"inline_data": payload}]}]
                        await session.send_client_content(
                            turns=turns, turn_complete=True
                        )
        except asyncio.CancelledError:
            raise

    def _dump_frame(self, payload: FramePayload) -> None:
        directory = self._options.frame_dump_dir
        if directory is None:
            return

        path = directory / f"{time.time_ns()}.jpg"
        try:
            data = base64.b64decode(payload["data"], validate=True)
            path.write_bytes(data)
        except Exception:  # pragma: no cover - best-effort logging
            LOGGER.exception("Failed to dump frame to %s", path)

    async def _consume_responses(self, session: LiveSession) -> None:
        try:
            while True:
                turn = session.receive()
                async for response in turn:
                    text = getattr(response, "text", None)
                    if text:
                        print(text, end="", flush=True)
        except asyncio.CancelledError:
            raise
