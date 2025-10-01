use scap::capturer::{Capturer, Options};
use std::sync::Arc;
use watcher_core::{
    ensure_clean_directory, ensure_screen_recording_permission, CaptureSession,
    CliResponsePrinter, ConnectionOptions, Content, FrameSource, GenerationConfig, GeminiSession,
    OutputProcessor, Setup,
};

#[tokio::main]
async fn main() {
    // Check permissions
    if let Err(e) = ensure_screen_recording_permission() {
        eprintln!("❌ Permission error: {}", e);
        return;
    }

    // Get API key
    let api_key =
        std::env::var("GOOGLE_API_KEY").expect("GOOGLE_API_KEY environment variable must be set");

    // Setup Gemini session
    let connection_options = ConnectionOptions::builder()
        .api_key(api_key)
        .build()
        .expect("Failed to build connection options");

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
        .expect("Failed to build setup");

    let session = GeminiSession::connect(setup, connection_options)
        .await
        .expect("Failed to connect to Gemini");

    let sender = session.sender_handle();
    let printer: Arc<dyn watcher_core::ResponsePrinter> = Arc::new(CliResponsePrinter::new());

    // Start output processor to handle Gemini responses
    let output_processor = OutputProcessor::new(Arc::clone(&printer));
    output_processor.spawn(session);

    // Ensure output directory is clean
    ensure_clean_directory("output").expect("Failed to create output directory");

    // Configure screen capturer
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
    let frame_source = FrameSource::new(capturer);

    println!("📸 Capturing frames at 1 FPS and sending to Gemini...");
    println!("💾 Saving frames to output/ directory as JPEG");
    println!("Press Ctrl+C to stop\n");

    // Run capture session
    let session = CaptureSession::new(frame_source, sender.clone(), printer, "output".to_string());

    if let Err(e) = session.capture_frames(10).await {
        eprintln!("❌ Capture error: {}", e);
    }

    println!("\n✅ Capture stopped. Closing Gemini session...");
    sender.close().await.ok();
    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
}
