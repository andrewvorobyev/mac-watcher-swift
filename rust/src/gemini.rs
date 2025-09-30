#![allow(dead_code)]

use std::{
    collections::VecDeque,
    fmt,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use base64::Engine as _;
use derive_builder::Builder;
use futures::{SinkExt, StreamExt};
use http::{
    Request, StatusCode,
    header::{AUTHORIZATION, HeaderValue},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::{net::TcpStream, sync::Mutex};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{self, client::IntoClientRequest, protocol::Message},
};
use url::Url;

/// The public preview endpoint for Gemini Live API sessions.
pub const DEFAULT_LIVE_ENDPOINT: &str = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

/// Convenience result alias for Gemini live operations.
pub type Result<T> = std::result::Result<T, GeminiError>;

type InnerStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type Sender = futures::stream::SplitSink<InnerStream, Message>;
type Receiver = futures::stream::SplitStream<InnerStream>;
type SharedSender = Arc<Mutex<Sender>>;

/// Errors that can arise while using the Gemini live API helper.
#[derive(Debug, Error)]
pub enum GeminiError {
    #[error("invalid endpoint: {0}")]
    InvalidEndpoint(#[from] url::ParseError),

    #[error("failed to build websocket request: {0}")]
    RequestBuild(#[from] tungstenite::error::UrlError),

    #[error("invalid header value: {0}")]
    InvalidHeaderValue(#[from] http::header::InvalidHeaderValue),

    #[error("websocket protocol error: {0}")]
    WebSocket(#[from] tungstenite::Error),

    #[error("failed to encode or decode JSON: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("connection closed")]
    ConnectionClosed,

    #[error("server closed the connection before acknowledging setup")]
    SetupNotAcknowledged,

    #[error("server responded with more than one message type: {0:?}")]
    MultipleServerMessageTypes(Vec<String>),

    #[error("unexpected server message: {0}")]
    UnexpectedServerMessage(Value),

    #[error("server returned error: {0}")]
    ServerError(ErrorResponse),

    #[error("websocket handshake failed with status {0}")]
    HandshakeStatus(StatusCode),

    #[error("server closed the connection: code {code}, reason {reason}")]
    ServerClosed { code: String, reason: String },
}

/// Connection parameters for creating a Gemini live session.
#[derive(Debug, Clone, Builder)]
#[builder(pattern = "owned")]
pub struct ConnectionOptions {
    #[builder(default = "Url::parse(DEFAULT_LIVE_ENDPOINT).expect(\"valid default endpoint\")")]
    endpoint: Url,
    #[builder(setter(strip_option, into), default)]
    api_key: Option<String>,
    #[builder(setter(strip_option, into), default)]
    access_token: Option<String>,
}

impl ConnectionOptions {
    /// Creates a new set of connection options pointing at the default live endpoint.
    pub fn new() -> Self {
        Self::builder()
            .build()
            .expect("builder defaults to produce valid connection options")
    }

    /// Returns the configured endpoint URL.
    pub fn endpoint(&self) -> &Url {
        &self.endpoint
    }

    /// Returns a builder for customizing the connection options.
    pub fn builder() -> ConnectionOptionsBuilder {
        ConnectionOptionsBuilder::default()
    }

    fn build_request(&self) -> Result<Request<()>> {
        let mut url = self.endpoint.clone();
        {
            let mut pairs = url.query_pairs_mut();
            if let Some(key) = &self.api_key {
                pairs.append_pair("key", key);
            }
            if let Some(token) = &self.access_token {
                pairs.append_pair("access_token", token);
            }
        }
        let mut request: Request<()> = url.into_client_request()?;

        if let Some(key) = &self.api_key {
            let value = HeaderValue::from_str(key)?;
            request.headers_mut().insert("X-Goog-Api-Key", value);
        }

        if let Some(token) = &self.access_token {
            let bearer = format!("Bearer {}", token);
            let value = HeaderValue::from_str(&bearer)?;
            request.headers_mut().insert(AUTHORIZATION, value);
        }

        Ok(request)
    }
}

/// Wrapper around an active Gemini live session.
pub struct GeminiSession {
    sender: SharedSender,
    receiver: Receiver,
    pending: VecDeque<ServerEvent>,
    closed: Arc<AtomicBool>,
}

async fn send_message_internal(
    sender: &SharedSender,
    closed: &Arc<AtomicBool>,
    message: ClientMessage,
) -> Result<()> {
    if closed.load(Ordering::SeqCst) {
        return Err(GeminiError::ConnectionClosed);
    }
    let payload = serde_json::to_string(&message)?;
    let mut sink = sender.lock().await;
    sink.send(Message::Text(payload)).await?;
    Ok(())
}

impl GeminiSession {
    /// Opens a new WebSocket connection, sends the setup frame, and waits for acknowledgment.
    pub async fn connect(setup: Setup, options: ConnectionOptions) -> Result<Self> {
        let request = options.build_request()?;
        let (ws_stream, response) = connect_async(request).await?;
        if response.status() != StatusCode::SWITCHING_PROTOCOLS {
            return Err(GeminiError::HandshakeStatus(response.status()));
        }
        let (sender, receiver) = ws_stream.split();
        let sender = Arc::new(Mutex::new(sender));
        let closed = Arc::new(AtomicBool::new(false));

        let mut session = Self {
            sender,
            receiver,
            pending: VecDeque::new(),
            closed,
        };

        session.send_setup(setup).await?;
        session.expect_setup_complete().await?;
        Ok(session)
    }

    /// Returns a clonable sender handle that can be used from other tasks.
    pub fn sender_handle(&self) -> GeminiSender {
        GeminiSender {
            sender: self.sender.clone(),
            closed: self.closed.clone(),
        }
    }

    /// Sends a raw client message to the server.
    pub async fn send_message(&self, message: ClientMessage) -> Result<()> {
        send_message_internal(&self.sender, &self.closed, message).await
    }

    /// Sends a `clientContent` message.
    pub async fn send_client_content(&self, content: ClientContent) -> Result<()> {
        self.send_message(ClientMessage::ClientContent(content))
            .await
    }

    /// Adds a helper to send a single text turn and optionally mark it as complete.
    pub async fn send_text_turn(
        &self,
        role: impl Into<String>,
        text: impl Into<String>,
        turn_complete: bool,
    ) -> Result<()> {
        let mut content = ClientContent {
            turns: vec![Content::text(role, text)],
            ..Default::default()
        };
        if turn_complete {
            content.turn_complete = Some(true);
        }
        self.send_client_content(content).await
    }

    /// Sends a `realtimeInput` message, useful for low-latency text or audio streaming.
    pub async fn send_realtime_text(&self, text: impl Into<String>) -> Result<()> {
        self.send_message(ClientMessage::RealtimeInput(RealtimeInput {
            text: Some(text.into()),
            ..Default::default()
        }))
        .await
    }

    /// Sends a tool response payload back to the model.
    pub async fn send_tool_response(&self, response: ToolResponse) -> Result<()> {
        self.send_message(ClientMessage::ToolResponse(response))
            .await
    }

    /// Receives the next server event, if the connection is still open.
    pub async fn recv(&mut self) -> Result<Option<ServerEvent>> {
        if let Some(event) = self.pending.pop_front() {
            return Ok(Some(event));
        }
        self.read_next_event().await
    }

    /// Closes the WebSocket connection gracefully.
    pub async fn close(&mut self) -> Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            return Ok(());
        }
        {
            let mut sender = self.sender.lock().await;
            sender.send(Message::Close(None)).await?;
        }
        self.closed.store(true, Ordering::SeqCst);
        Ok(())
    }

    async fn send_setup(&self, setup: Setup) -> Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(GeminiError::ConnectionClosed);
        }
        let payload = serde_json::to_string(&json!({ "setup": setup }))?;
        let mut sender = self.sender.lock().await;
        sender.send(Message::Text(payload)).await?;
        Ok(())
    }

    async fn expect_setup_complete(&mut self) -> Result<()> {
        loop {
            match self.read_next_event().await? {
                Some(ServerEvent::SetupComplete { .. }) => return Ok(()),
                Some(ServerEvent::Error { error, .. }) => {
                    return Err(GeminiError::ServerError(error));
                }
                Some(other) => self.pending.push_back(other),
                None => return Err(GeminiError::SetupNotAcknowledged),
            }
        }
    }

    async fn read_next_event(&mut self) -> Result<Option<ServerEvent>> {
        if self.closed.load(Ordering::SeqCst) {
            return Ok(None);
        }

        while let Some(frame) = self.receiver.next().await {
            let message = frame?;
            match message {
                Message::Text(text) => {
                    let value: Value = serde_json::from_str(&text)?;
                    let event = parse_server_event(value)?;
                    return Ok(Some(event));
                }
                Message::Binary(bytes) => {
                    let value: Value = serde_json::from_slice(&bytes)?;
                    let event = parse_server_event(value)?;
                    return Ok(Some(event));
                }
                Message::Ping(payload) => {
                    let mut sender = self.sender.lock().await;
                    sender.send(Message::Pong(payload)).await?;
                }
                Message::Pong(_) => {}
                Message::Close(frame) => {
                    self.closed.store(true, Ordering::SeqCst);
                    if let Some(frame) = frame {
                        let reason = frame.reason.to_string();
                        let code = format!("{:?}", frame.code);
                        return Err(GeminiError::ServerClosed { code, reason });
                    }
                    return Ok(None);
                }
                Message::Frame(_) => {}
            }
        }

        self.closed.store(true, Ordering::SeqCst);
        Ok(None)
    }
}

#[derive(Clone)]
pub struct GeminiSender {
    sender: SharedSender,
    closed: Arc<AtomicBool>,
}

impl GeminiSender {
    async fn send_message(&self, message: ClientMessage) -> Result<()> {
        send_message_internal(&self.sender, &self.closed, message).await
    }

    pub async fn send_client_content(&self, content: ClientContent) -> Result<()> {
        self.send_message(ClientMessage::ClientContent(content))
            .await
    }

    pub async fn send_text_turn(
        &self,
        role: impl Into<String>,
        text: impl Into<String>,
        turn_complete: bool,
    ) -> Result<()> {
        let mut content = ClientContent {
            turns: vec![Content::text(role, text)],
            ..Default::default()
        };
        if turn_complete {
            content.turn_complete = Some(true);
        }
        self.send_client_content(content).await
    }

    pub async fn send_realtime_text(&self, text: impl Into<String>) -> Result<()> {
        self.send_message(ClientMessage::RealtimeInput(RealtimeInput {
            text: Some(text.into()),
            ..Default::default()
        }))
        .await
    }

    pub async fn send_tool_response(&self, response: ToolResponse) -> Result<()> {
        self.send_message(ClientMessage::ToolResponse(response))
            .await
    }

    pub async fn close(&self) -> Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            return Ok(());
        }
        {
            let mut sender = self.sender.lock().await;
            sender.send(Message::Close(None)).await?;
        }
        self.closed.store(true, Ordering::SeqCst);
        Ok(())
    }
}

fn parse_server_event(value: Value) -> Result<ServerEvent> {
    let mut object = match value {
        Value::Object(map) => map,
        other => return Err(GeminiError::UnexpectedServerMessage(other)),
    };

    let usage_metadata = if let Some(raw) = object.remove("usageMetadata") {
        Some(serde_json::from_value(raw)?)
    } else {
        None
    };

    if let Some(raw_error) = object.remove("error") {
        let error: ErrorResponse = serde_json::from_value(raw_error)?;
        return Ok(ServerEvent::Error {
            usage_metadata,
            error,
        });
    }

    let known_keys = [
        "setupComplete",
        "serverContent",
        "toolCall",
        "toolCallCancellation",
        "goAway",
        "sessionResumptionUpdate",
    ];

    let matched: Vec<String> = known_keys
        .iter()
        .filter(|key| object.contains_key(**key))
        .map(|key| (*key).to_string())
        .collect();

    if matched.len() > 1 {
        return Err(GeminiError::MultipleServerMessageTypes(matched));
    }

    if let Some(kind) = matched.first() {
        match kind.as_str() {
            "setupComplete" => {
                serde_json::from_value::<SetupComplete>(
                    object.remove("setupComplete").unwrap_or(Value::Null),
                )?;
                Ok(ServerEvent::SetupComplete { usage_metadata })
            }
            "serverContent" => {
                let payload = object.remove("serverContent").unwrap_or(Value::Null);
                let content: ServerContent = serde_json::from_value(payload)?;
                Ok(ServerEvent::ServerContent {
                    usage_metadata,
                    content,
                })
            }
            "toolCall" => {
                let payload = object.remove("toolCall").unwrap_or(Value::Null);
                let message: ToolCall = serde_json::from_value(payload)?;
                Ok(ServerEvent::ToolCall {
                    usage_metadata,
                    tool_call: message,
                })
            }
            "toolCallCancellation" => {
                let payload = object.remove("toolCallCancellation").unwrap_or(Value::Null);
                let cancellation: ToolCallCancellation = serde_json::from_value(payload)?;
                Ok(ServerEvent::ToolCallCancellation {
                    usage_metadata,
                    cancellation,
                })
            }
            "goAway" => {
                let payload = object.remove("goAway").unwrap_or(Value::Null);
                let go_away: GoAway = serde_json::from_value(payload)?;
                Ok(ServerEvent::GoAway {
                    usage_metadata,
                    go_away,
                })
            }
            "sessionResumptionUpdate" => {
                let payload = object
                    .remove("sessionResumptionUpdate")
                    .unwrap_or(Value::Null);
                let update: SessionResumptionUpdate = serde_json::from_value(payload)?;
                Ok(ServerEvent::SessionResumptionUpdate {
                    usage_metadata,
                    update,
                })
            }
            _ => unreachable!(),
        }
    } else {
        Ok(ServerEvent::Unknown {
            usage_metadata,
            raw: Value::Object(object),
        })
    }
}

/// Represents any message a client can send to the Gemini live service.
#[derive(Debug, Serialize, Clone)]
pub enum ClientMessage {
    #[serde(rename = "clientContent")]
    ClientContent(ClientContent),
    #[serde(rename = "realtimeInput")]
    RealtimeInput(RealtimeInput),
    #[serde(rename = "toolResponse")]
    ToolResponse(ToolResponse),
}

/// Session setup payload as required by the first message on a live session.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Setup {
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation_config: Option<GenerationConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_instruction: Option<Content>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub realtime_input_config: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_resumption: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window_compression: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_audio_transcription: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_audio_transcription: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proactivity: Option<Value>,
}

impl Setup {
    /// Creates a minimal setup structure for a given model name.
    pub fn new(model: impl Into<String>) -> Self {
        Self {
            model: model.into(),
            ..Default::default()
        }
    }
}

/// Model generation configuration mirrors the REST API structure.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct GenerationConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidate_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_k: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presence_penalty: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frequency_penalty: Option<f32>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub response_modalities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speech_config: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_resolution: Option<Value>,
}

/// Content turn payload appended to the conversation history.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ClientContent {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub turns: Vec<Content>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_complete: Option<bool>,
}

/// Realtime input payload for low-latency audio/video/text streaming.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_chunks: Option<Vec<Blob>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio: Option<Blob>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video: Option<Blob>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity_start: Option<ActivitySignal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity_end: Option<ActivitySignal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_stream_end: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Activity signal marker used when automatic detection is disabled.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySignal {}

/// Tool response payload.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ToolResponse {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub function_responses: Vec<FunctionResponse>,
}

/// Standard error payload returned by the Gemini service.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ErrorResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub details: Vec<Value>,
}

impl fmt::Display for ErrorResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (&self.message, self.code, &self.status) {
            (Some(message), Some(code), Some(status)) => {
                write!(f, "{} (code {}, status {})", message, code, status)
            }
            (Some(message), Some(code), None) => write!(f, "{} (code {})", message, code),
            (Some(message), None, Some(status)) => {
                write!(f, "{} (status {})", message, status)
            }
            (Some(message), None, None) => write!(f, "{}", message),
            (None, Some(code), Some(status)) => {
                write!(f, "code {}, status {}", code, status)
            }
            (None, Some(code), None) => write!(f, "code {}", code),
            (None, None, Some(status)) => write!(f, "status {}", status),
            (None, None, None) => write!(f, "unknown error"),
        }
    }
}

/// Response to a single tool call.
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct FunctionResponse {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response: Option<Value>,
}

impl FunctionResponse {
    /// Convenience constructor for JSON responses.
    pub fn new(id: impl Into<String>, name: impl Into<String>, response: Value) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            response: Some(response),
        }
    }
}

/// Binary payload helper for audio/video frames.
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Blob {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    pub data: String,
}

impl Blob {
    /// Creates a blob by base64-encoding the provided bytes.
    pub fn from_bytes(bytes: &[u8]) -> Self {
        Self {
            mime_type: None,
            data: base64::engine::general_purpose::STANDARD.encode(bytes),
        }
    }

    /// Sets the MIME type for the blob.
    pub fn with_mime_type(mut self, mime_type: impl Into<String>) -> Self {
        self.mime_type = Some(mime_type.into());
        self
    }
}

/// Conversation content shared between client and server messages.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Content {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub parts: Vec<Part>,
}

impl Content {
    /// Builds a simple text turn with the provided role.
    pub fn text(role: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            role: Some(role.into()),
            parts: vec![Part::text(text)],
        }
    }

    /// Builds a system text instruction.
    pub fn system(text: impl Into<String>) -> Self {
        Self {
            role: Some("system".to_string()),
            parts: vec![Part::text(text)],
        }
    }
}

/// A single content part.
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(untagged)]
pub enum Part {
    Text { text: String },
    Json(Value),
}

impl Part {
    pub fn text(text: impl Into<String>) -> Self {
        Part::Text { text: text.into() }
    }

    pub fn json(value: Value) -> Self {
        Part::Json(value)
    }
}

/// Messages broadcast by the server during a live session.
#[derive(Debug, Clone)]
pub enum ServerEvent {
    SetupComplete {
        usage_metadata: Option<UsageMetadata>,
    },
    ServerContent {
        usage_metadata: Option<UsageMetadata>,
        content: ServerContent,
    },
    ToolCall {
        usage_metadata: Option<UsageMetadata>,
        tool_call: ToolCall,
    },
    ToolCallCancellation {
        usage_metadata: Option<UsageMetadata>,
        cancellation: ToolCallCancellation,
    },
    GoAway {
        usage_metadata: Option<UsageMetadata>,
        go_away: GoAway,
    },
    SessionResumptionUpdate {
        usage_metadata: Option<UsageMetadata>,
        update: SessionResumptionUpdate,
    },
    Error {
        usage_metadata: Option<UsageMetadata>,
        error: ErrorResponse,
    },
    Unknown {
        usage_metadata: Option<UsageMetadata>,
        raw: Value,
    },
}

/// Server acknowledgement to a setup frame.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct SetupComplete {}

/// Incremental content streamed from the model.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ServerContent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation_complete: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_complete: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interrupted: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grounding_metadata: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_transcription: Option<Transcription>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_transcription: Option<Transcription>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url_context_metadata: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_turn: Option<Content>,
}

/// Transcription payload for audio streams.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Transcription {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Usage metadata published alongside server responses.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct UsageMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_token_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cached_content_token_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response_token_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_prompt_token_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thoughts_token_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_token_count: Option<i32>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub prompt_tokens_details: Vec<Value>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub cache_tokens_details: Vec<Value>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub response_tokens_details: Vec<Value>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub tool_use_prompt_tokens_details: Vec<Value>,
}

/// Tool call request emitted by the model.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub function_calls: Vec<FunctionCall>,
}

/// A single function call issued by the model.
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct FunctionCall {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub args: Option<Value>,
}

/// Notification that a previously issued tool call should be cancelled.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallCancellation {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ids: Vec<String>,
}

/// Server notice indicating the connection will close.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct GoAway {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_left: Option<Value>,
}

/// Session resumption state updates.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionResumptionUpdate {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_handle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resumable: Option<bool>,
}

impl Default for ConnectionOptions {
    fn default() -> Self {
        ConnectionOptions::new()
    }
}
