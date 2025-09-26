"""CLI entrypoint for streaming video frames to the Gemini realtime API."""

from __future__ import annotations

import asyncio
import logging

from google import genai
from google.genai.types import LiveConnectConfigDict, Modality

from watcher import tools
from watcher.frames import CaptureMode, FrameSourceSpec
from watcher.streamer import GeminiRealtimeStreamer, LiveApiMode, StreamerOptions
from watcher.utils import OUT_PATH, PROMPTS_PATH

LOGGER = logging.getLogger(__name__)


async def main() -> None:
    logging.basicConfig(level=logging.INFO)

    frame_source = FrameSourceSpec(
        mode=CaptureMode.SCREEN,
        fps=1.0,
        max_dimension=1024,
        jpeg_quality=85,
        camera_index=0,
        monitor_index=1,
    ).build()

    model = "gemini-live-2.5-flash-preview"  # Half-cascade audio (https://ai.google.dev/gemini-api/docs/live)
    prompt = (PROMPTS_PATH / "system.md").read_text()

    client = genai.Client()

    streamer_opts = StreamerOptions(
        model=model,
        config=LiveConnectConfigDict(
            response_modalities=[Modality.TEXT], tools=[tools.report_activity]
        ),
        initial_text=prompt,
        frame_dump_dir=OUT_PATH,
        api_mode=LiveApiMode.REALTIME,
    )

    streamer = GeminiRealtimeStreamer(client=client, options=streamer_opts)
    await streamer.stream(frame_source)


if __name__ == "__main__":
    asyncio.run(main())
