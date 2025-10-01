use crate::{Content, GeminiSession, Part, ServerEvent};
use std::sync::Arc;

/// Trait for printing Gemini responses
pub trait ResponsePrinter: Send + Sync {
    fn print_response(&self, content: &Content);
}

/// CLI implementation that prints responses to stdout
pub struct CliResponsePrinter;

impl CliResponsePrinter {
    pub fn new() -> Self {
        Self
    }
}

impl Default for CliResponsePrinter {
    fn default() -> Self {
        Self::new()
    }
}

impl ResponsePrinter for CliResponsePrinter {
    fn print_response(&self, content: &Content) {
        for part in &content.parts {
            match part {
                Part::Text { text } => {
                    println!("🤖 Gemini: {}", text);
                }
                Part::Json(value) => {
                    println!("🤖 Gemini (json): {}", value);
                }
            }
        }
    }
}

/// Processes Gemini session output by receiving events and printing responses
pub struct OutputProcessor {
    printer: Arc<dyn ResponsePrinter>,
}

impl OutputProcessor {
    pub fn new(printer: Arc<dyn ResponsePrinter>) -> Self {
        Self { printer }
    }

    /// Spawns a task to process Gemini session events
    pub fn spawn(self, session: GeminiSession) {
        tokio::spawn(async move {
            let mut session = session;
            loop {
                match session.recv().await {
                    Ok(Some(ServerEvent::ServerContent { content, .. })) => {
                        if let Some(model_turn) = content.model_turn {
                            self.printer.print_response(&model_turn);
                        }
                        if content.generation_complete.unwrap_or(false) {
                            println!();
                        }
                    }
                    Ok(Some(ServerEvent::SetupComplete { .. })) => {
                        println!("✅ Gemini session ready");
                    }
                    Ok(Some(ServerEvent::Error { error, .. })) => {
                        eprintln!("❌ Gemini error: {}", error);
                    }
                    Ok(None) => break,
                    Err(err) => {
                        eprintln!("❌ Receiver error: {}", err);
                        break;
                    }
                    _ => {}
                }
            }
        });
    }
}
