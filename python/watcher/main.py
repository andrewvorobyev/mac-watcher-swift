"""CLI entrypoint for streaming video frames to the Gemini realtime API."""

from __future__ import annotations

import asyncio
import logging

from google import genai
from google.genai.types import LiveConnectConfigDict
from watcher.frames import CaptureMode, FrameSourceSpec, create_frame_source
from watcher.streamer import GeminiRealtimeStreamer, StreamerOptions

import os


LOGGER = logging.getLogger(__name__)


FRAME_SOURCE_SPEC = FrameSourceSpec(
    mode=CaptureMode.SCREEN,
    fps=1.0,
    max_dimension=1024,
    jpeg_quality=85,
    camera_index=0,
    monitor_index=1,
)

MODEL_ID = "models/gemini-2.0-flash-live-001"
INITIAL_PROMPT: str | None = "Output short description of what you see on the screen"


async def run_async() -> None:
    client = genai.Client(http_options={"api_version": "v1beta"})
    options = StreamerOptions(
        model=MODEL_ID,
        config=LiveConnectConfigDict(),
        initial_text=INITIAL_PROMPT,
    )
    frame_source = create_frame_source(FRAME_SOURCE_SPEC)
    streamer = GeminiRealtimeStreamer(client=client, options=options)
    await streamer.stream(frame_source)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    try:
        asyncio.run(run_async())
    except KeyboardInterrupt:
        LOGGER.info("Interrupted by user; shutting down.")


if __name__ == "__main__":
    main()
