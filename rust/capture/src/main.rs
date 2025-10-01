use base64::Engine;
use scap::capturer::{Capturer, Options};
use serde_json::json;
use watcher_core::{
    encode_bgra_to_jpeg_bytes, ensure_clean_directory, ClientContent, ConnectionOptions, Content,
    FrameSource, GenerationConfig, GeminiSession, Part, ServerEvent, Setup,
};

#[tokio::main]
async fn main() {
    println!("Starting screen capture example...");

    // Check if platform is supported
    if !scap::is_supported() {
        eprintln!("❌ Platform not supported");
        return;
    }

    // Check and request permission
    if !scap::has_permission() {
        println!("❌ Screen recording permission not granted.");
        println!("📋 Please grant permission:");
        println!("   1. Open System Settings");
        println!("   2. Go to Privacy & Security → Screen Recording");
        println!("   3. Enable permission for your Terminal app");
        println!("   4. Restart your terminal and try again");

        // Attempt to request permission (will open system dialog on some platforms)
        if scap::request_permission() {
            println!("✅ Permission granted!");
        } else {
            println!("❌ Permission denied or unavailable");
            return;
        }
    }

    // Get API key
    let api_key =
        std::env::var("GOOGLE_API_KEY").expect("GOOGLE_API_KEY environment variable must be set");

    // Setup Gemini session
    let connection_options = ConnectionOptions::builder()
        .api_key(api_key)
        .build()
        .expect("connection options builder should set all fields");

    let setup = Setup::builder("models/gemini-live-2.5-flash-preview")
        .system_instruction(Content::system(
            "You are analyzing screenshots of a user's computer screen. \
             For each screenshot, provide a brief description of what the user is doing. \
             Focus on the main activity visible on the screen. Keep your response concise (1-2 sentences).",
        ))
        .generation_config(GenerationConfig {
            response_modalities: vec!["TEXT".to_string()],
            ..Default::default()
        })
        .build()
        .expect("setup builder should initialize required fields");

    let session = GeminiSession::connect(setup, connection_options)
        .await
        .expect("Failed to connect to Gemini");

    let sender = session.sender_handle();

    // Spawn receiver task
    tokio::spawn(async move {
        let mut session = session;
        loop {
            match session.recv().await {
                Ok(Some(ServerEvent::ServerContent { content, .. })) => {
                    if let Some(model_turn) = content.model_turn {
                        print_model_response(&model_turn);
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

    // Ensure output directory is clean
    ensure_clean_directory("output").expect("Failed to create output directory");

    // Configure scap capturer with 1 FPS
    let capture_options = Options {
        fps: 1,
        target: None,
        show_cursor: true,
        show_highlight: true,
        excluded_targets: None,
        output_type: scap::frame::FrameType::BGRAFrame,
        output_resolution: scap::capturer::Resolution::_720p,
        crop_area: None,
        captures_audio: false,
        exclude_current_process_audio: false,
    };

    let capturer = Capturer::build(capture_options).expect("Failed to create capturer");

    // Create FrameSource wrapper that manages the last frame
    let frame_source = FrameSource::new(capturer);

    println!("📸 Capturing frames at 1 FPS and sending to Gemini...");
    println!("💾 Saving frames to output/ directory as JPEG");
    println!("Press Ctrl+C to stop\n");

    // Capture frames for 10 seconds
    for i in 1..=10 {
        match frame_source.get_next_frame().await {
            Ok(frame) => {
                let filename = format!("output/frame_{:04}.jpg", i);

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

                        if let Err(e) = sender.send_client_content(content).await {
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

    println!("\n✅ Capture stopped. Closing Gemini session...");
    sender.close().await.ok();
    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
}

fn print_model_response(content: &Content) {
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
