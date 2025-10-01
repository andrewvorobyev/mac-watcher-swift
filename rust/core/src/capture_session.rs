use crate::{
    encode_bgra_to_jpeg_bytes, ClientContent, Content, FrameSource, GeminiSender, Part,
    ResponsePrinter,
};
use base64::Engine;
use serde_json::json;
use std::sync::Arc;

pub struct CaptureSession {
    frame_source: FrameSource,
    sender: GeminiSender,
    _printer: Arc<dyn ResponsePrinter>,
    output_dir: String,
}

impl CaptureSession {
    pub fn new(
        frame_source: FrameSource,
        sender: GeminiSender,
        printer: Arc<dyn ResponsePrinter>,
        output_dir: String,
    ) -> Self {
        Self {
            frame_source,
            sender,
            _printer: printer,
            output_dir,
        }
    }

    /// Captures frames and sends them to Gemini for analysis
    pub async fn capture_frames(&self, count: usize) -> crate::gemini::Result<()> {
        for i in 1..=count {
            match self.frame_source.get_next_frame().await {
                Ok(frame) => {
                    let filename = format!("{}/frame_{:04}.jpg", self.output_dir, i);

                    // Encode as JPEG bytes
                    match encode_bgra_to_jpeg_bytes(&frame.data, frame.width, frame.height, 90) {
                        Ok(jpeg_bytes) => {
                            // Save to file
                            if let Err(e) = std::fs::write(&filename, &jpeg_bytes) {
                                eprintln!("❌ Error saving frame {}: {}", i, e);
                                continue;
                            }

                            println!(
                                "📸 Frame {}: {}x{} pixels -> {}",
                                i, frame.width, frame.height, filename
                            );

                            // Encode to base64 for Gemini
                            let base64_image =
                                base64::engine::general_purpose::STANDARD.encode(&jpeg_bytes);

                            // Send to Gemini with inline image data
                            let content = ClientContent {
                                turns: vec![Content {
                                    role: Some("user".to_string()),
                                    parts: vec![
                                        Part::json(json!({
                                            "inline_data": {
                                                "mime_type": "image/jpeg",
                                                "data": base64_image
                                            }
                                        })),
                                        Part::text("What is the user doing in this screenshot?"),
                                    ],
                                }],
                                turn_complete: Some(true),
                                ..Default::default()
                            };

                            if let Err(e) = self.sender.send_client_content(content).await {
                                eprintln!("❌ Error sending to Gemini: {}", e);
                            }
                        }
                        Err(e) => {
                            eprintln!("❌ Error encoding frame {}: {}", i, e);
                        }
                    }
                }
                Err(e) => {
                    eprintln!("❌ Error getting frame: {}", e);
                }
            }
        }

        Ok(())
    }
}
