"""CLI entrypoint for streaming video frames to the Gemini realtime API."""

from __future__ import annotations

import argparse
import asyncio
import logging
from typing import Sequence

from google import genai

from watcher.frames import CaptureMode, FrameSourceSpec, create_frame_source
from watcher.streamer import GeminiRealtimeStreamer, LiveSessionConfig, StreamerOptions


LOGGER = logging.getLogger(__name__)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Stream video frames to Gemini Realtime")
    parser.add_argument(
        "--mode",
        type=CaptureMode,
        choices=list(CaptureMode),
        default=CaptureMode.SCREEN,
        help="Select the input source for frames.",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=1.0,
        help="Frame rate used when capturing video.",
    )
    parser.add_argument(
        "--max-dimension",
        dest="max_dimension",
        type=int,
        default=1024,
        help="Largest edge size (in pixels) before downscaling captured frames.",
    )
    parser.add_argument(
        "--jpeg-quality",
        dest="jpeg_quality",
        type=int,
        default=85,
        help="Quality factor (1-100) supplied to the JPEG encoder.",
    )
    parser.add_argument(
        "--camera-index",
        dest="camera_index",
        type=int,
        default=0,
        help="Camera index used when mode=camera.",
    )
    parser.add_argument(
        "--monitor-index",
        dest="monitor_index",
        type=int,
        default=1,
        help="Monitor number used when mode=screen (1 is usually the primary display).",
    )
    parser.add_argument(
        "--model",
        default="models/gemini-2.0-flash-live-001",
        help="Gemini live model identifier.",
    )
    parser.add_argument(
        "--prompt",
        default=None,
        help="Optional text prompt sent before the first frame.",
    )
    return parser.parse_args(argv)


def build_frame_spec(args: argparse.Namespace) -> FrameSourceSpec:
    return FrameSourceSpec(
        mode=args.mode,
        fps=args.fps,
        max_dimension=args.max_dimension,
        jpeg_quality=args.jpeg_quality,
        camera_index=args.camera_index,
        monitor_index=args.monitor_index,
    )


async def run_async(args: argparse.Namespace) -> None:
    client = genai.Client(http_options={"api_version": "v1beta"})
    options = StreamerOptions(
        model=args.model,
        config=LiveSessionConfig(),
        initial_text=args.prompt,
    )
    frame_source = create_frame_source(build_frame_spec(args))
    streamer = GeminiRealtimeStreamer(client=client, options=options)
    await streamer.stream(frame_source)


def main(argv: Sequence[str] | None = None) -> None:
    logging.basicConfig(level=logging.INFO)
    args = parse_args(argv)
    try:
        asyncio.run(run_async(args))
    except KeyboardInterrupt:
        LOGGER.info("Interrupted by user; shutting down.")


if __name__ == "__main__":
    main()

