"""Gemini realtime streaming orchestration."""

import asyncio
import logging
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from google import genai
from google.genai.types import LiveConnectConfigDict

from watcher.frames import FrameSource
from watcher.live_session import LiveSession

LOGGER = logging.getLogger(__name__)


class Streamer(Protocol):
    async def stream(self, source: FrameSource) -> None: ...


class LiveApiMode(StrEnum):
    REALTIME = "REALTIME"
    SEQUENTIAL = "SEQUENTIAL"


@dataclass(slots=True)
class StreamerOptions:
    client: genai.Client
    mode: LiveApiMode
    model: str
    config: LiveConnectConfigDict
    model_instructions: str | None = None

    def build(self) -> "Streamer":
        match self.mode:
            case LiveApiMode.REALTIME:
                return RealtimeStreamer(self)
            case LiveApiMode.SEQUENTIAL:
                return SequentialStreamer(self)


@dataclass(frozen=True)
class RealtimeStreamer(Streamer):
    opts: StreamerOptions

    async def stream(self, source: FrameSource) -> None:
        async with source:
            async with self.opts.client.aio.live.connect(
                model=self.opts.model,
                config=self.opts.config,
            ) as session:
                if self.opts.model_instructions:
                    await session.send_realtime_input(text=self.opts.model_instructions)

                async with asyncio.TaskGroup() as group:
                    group.create_task(self._forward_frames(session, source))
                    group.create_task(self._consume_responses(session))

    async def _forward_frames(self, session: LiveSession, source: FrameSource) -> None:
        try:
            async for payload in source.frames():
                await session.send_realtime_input(media=payload)
                LOGGER.info("realtime input sent")
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


@dataclass(frozen=True)
class SequentialStreamer(Streamer):
    opts: StreamerOptions

    async def stream(self, source: FrameSource) -> None:
        async with source:
            async with self.opts.client.aio.live.connect(
                model=self.opts.model,
                config=self.opts.config,
            ) as session:
                if self.opts.model_instructions:
                    await session.send_client_content(
                        turns=[
                            {
                                "role": "user",
                                "parts": [{"text": self.opts.model_instructions}],
                            }
                        ],
                        turn_complete=False,
                    )

                async for payload in source.frames():
                    await session.send_client_content(
                        turns=[{"role": "user", "parts": [{"inline_data": payload}]}],
                        turn_complete=True,
                    )
