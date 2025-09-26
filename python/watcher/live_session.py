"""Protocol describing the subset of the Google GenAI live session API we use."""

from typing import AsyncIterator, Optional, Protocol, Sequence, Union

from google.genai import types


class LiveSession(Protocol):
    async def send(
        self,
        *,
        input: Optional[
            Union[
                types.ContentListUnion,
                types.ContentListUnionDict,
                types.LiveClientContentOrDict,
                types.LiveClientRealtimeInputOrDict,
                types.LiveClientToolResponseOrDict,
                types.FunctionResponseOrDict,
                Sequence[types.FunctionResponseOrDict],
            ]
        ] = None,
        end_of_turn: Optional[bool] = False,
    ) -> None: ...

    async def send_client_content(
        self,
        *,
        turns: Optional[
            Union[
                types.Content,
                types.ContentDict,
                list[Union[types.Content, types.ContentDict]],
            ]
        ] = None,
        turn_complete: bool = True,
    ) -> None: ...

    async def send_realtime_input(
        self,
        *,
        media: Optional[types.BlobImageUnionDict] = None,  # pyright: ignore[reportInvalidTypeForm]
        audio: Optional[types.BlobOrDict] = None,
        audio_stream_end: Optional[bool] = None,
        video: Optional[types.BlobImageUnionDict] = None,  # pyright: ignore[reportInvalidTypeForm]
        text: Optional[str] = None,
        activity_start: Optional[types.ActivityStartOrDict] = None,
        activity_end: Optional[types.ActivityEndOrDict] = None,
    ) -> None: ...

    async def send_tool_response(
        self,
        *,
        function_responses: Union[
            types.FunctionResponseOrDict,
            Sequence[types.FunctionResponseOrDict],
        ],
    ) -> None: ...

    def receive(self) -> AsyncIterator[types.LiveServerMessage]: ...

    def start_stream(
        self,
        *,
        stream: AsyncIterator[bytes],
        mime_type: str,
    ) -> AsyncIterator[types.LiveServerMessage]: ...

    async def close(self) -> None: ...
