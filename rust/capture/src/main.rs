use scap::capturer::{Capturer, Options};
use watcher_core::{encode_bgra_to_jpeg, ensure_clean_directory, FrameSource};

#[tokio::main]
async fn main() {
    println!("Starting screen capture example...");

    // Ensure output directory is clean
    ensure_clean_directory("output").expect("Failed to create output directory");

    // Configure scap capturer with 1 FPS
    let options = Options {
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

    let capturer = Capturer::build(options).expect("Failed to create capturer");

    // Create FrameSource wrapper that manages the last frame
    let frame_source = FrameSource::new(capturer);

    println!("Capturing frames at 1 FPS...");
    println!("Saving frames to output/ directory as JPEG");
    println!("Press Ctrl+C to stop\n");

    // Capture frames for 10 seconds
    for i in 1..=10 {
        match frame_source.get_next_frame().await {
            Ok(frame) => {
                let filename = format!("output/frame_{:04}.jpg", i);

                // Encode and save as JPEG
                match encode_bgra_to_jpeg(&frame.data, frame.width, frame.height, &filename, 90) {
                    Ok(_) => {
                        println!(
                            "Frame {}: {}x{} pixels -> {}",
                            i, frame.width, frame.height, filename
                        );
                    }
                    Err(e) => {
                        eprintln!("Error encoding frame {}: {}", i, e);
                    }
                }
            }
            Err(e) => {
                eprintln!("Error getting frame: {}", e);
            }
        }
    }

    println!("\nCapture stopped.");
}
