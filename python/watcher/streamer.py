"""Gemini realtime streaming orchestration."""

import asyncio
import logging
from dataclasses import dataclass

from google import genai
from google.genai.types import LiveConnectConfigDict

from watcher.frames import FrameSource
from watcher.live_session import LiveSession


LOGGER = logging.getLogger(__name__)


@dataclass(slots=True)
class StreamerOptions:
    """Control how the realtime session behaves."""

    model: str
    config: LiveConnectConfigDict
    initial_text: str | None = None

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
                    group.create_task(
                        self._forward_frames(session, source)
                    )  # pyright: ignore[reportArgumentType]
                    group.create_task(
                        self._consume_responses(session)
                    )  # pyright: ignore[reportArgumentType]

    async def _forward_frames(self, session: LiveSession, source: FrameSource) -> None:
        try:
            async for payload in source.frames():
                await session.send(input=payload)
                # await session.send(input={"role": "user", "parts": [{"text": "describe"}]})
                LOGGER.info("Frame sent")
        except asyncio.CancelledError:
            raise

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
