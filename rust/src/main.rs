mod gemini;

use std::time::Duration;

use crate::gemini::{
    ConnectionOptions, Content, GeminiSession, GenerationConfig, Part, ServerEvent, Setup,
    ToolResponse,
};
use tokio::time::sleep;

#[tokio::main]
async fn main() -> gemini::Result<()> {
    let api_key =
        std::env::var("GOOGLE_API_KEY").expect("GOOGLE_API_KEY environment variable must be set");

    let mut options_builder = ConnectionOptions::builder().api_key(api_key);
    if let Ok(token) = std::env::var("GEMINI_ACCESS_TOKEN") {
        options_builder = options_builder.access_token(token);
    }
    let options = options_builder
        .build()
        .expect("connection options builder should set all fields");

    let mut setup = Setup::new("models/gemini-live-2.5-flash-preview");
    setup.system_instruction = Some(Content::system(
        "You are a Rust sample app demonstrating the Gemini Live API.",
    ));
    setup.generation_config = Some(GenerationConfig {
        response_modalities: vec!["TEXT".to_string()],
        ..Default::default()
    });

    let session = GeminiSession::connect(setup, options).await?;
    let sender = session.sender_handle();
    let receiver_sender = sender.clone();

    tokio::spawn(async move {
        let mut session = session;
        let send_handle = receiver_sender;
        loop {
            match session.recv().await {
                Ok(Some(ServerEvent::ServerContent { content, .. })) => {
                    if let Some(model_turn) = content.model_turn {
                        print_model_turn(&model_turn);
                    }

                    if content.generation_complete.unwrap_or(false) {
                        println!();
                    }
                }
                Ok(Some(ServerEvent::ToolCall { tool_call, .. })) => {
                    println!("[tool-call] {:?}", tool_call.function_calls);
                    if let Err(err) = send_handle
                        .send_tool_response(ToolResponse::default())
                        .await
                    {
                        eprintln!("failed to send tool response: {}", err);
                    }
                }
                Ok(Some(ServerEvent::ToolCallCancellation { cancellation, .. })) => {
                    println!("[tool-call cancelled] {:?}", cancellation.ids);
                }
                Ok(Some(ServerEvent::GoAway { .. })) => {
                    println!("Server requested disconnect. Receiver exiting.");
                    break;
                }
                Ok(Some(ServerEvent::SessionResumptionUpdate { update, .. })) => {
                    if let Some(handle) = update.new_handle {
                        println!("[session resumable handle] {}", handle);
                    }
                }
                Ok(Some(ServerEvent::Error { error, .. })) => {
                    eprintln!("server error: {}", error);
                }
                Ok(Some(ServerEvent::SetupComplete { .. })) => {}
                Ok(Some(ServerEvent::Unknown { raw, .. })) => {
                    println!("[unknown message] {}", raw);
                }
                Ok(None) => break,
                Err(err) => {
                    eprintln!("receiver error: {}", err);
                    break;
                }
            }
        }
    });

    let prompts = [
        "Hello, Gemini!",
        "Share three fun facts about the Rust programming language.",
        "Thanks for the info!",
    ];

    for prompt in &prompts {
        println!("you > {}", prompt);
        sender
            .send_text_turn("user", prompt.to_string(), true)
            .await?;
        sleep(Duration::from_secs(1)).await;
    }

    sleep(Duration::from_secs(5)).await;
    sender.close().await.ok();
    Ok(())
}

fn print_model_turn(content: &Content) {
    let role = content.role.as_deref().unwrap_or("model");
    for part in &content.parts {
        match part {
            Part::Text { text } => {
                println!("model > {}", text);
            }
            Part::Json(value) => {
                println!("model > {} (json)", value);
            }
        }
    }
    if role != "model" {
        println!("[role: {}]", role);
    }
}
