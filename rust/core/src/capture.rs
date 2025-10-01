use scap::{
    capturer::Capturer as ScapCapturer,
    frame::{Frame, VideoFrame},
};
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::Notify;

#[derive(Debug, Error)]
pub enum CaptureError {
    #[error("Failed to get frame: {0}")]
    FrameError(String),
    #[error("No frame available")]
    NoFrameAvailable,
}

pub type CaptureResult<T> = std::result::Result<T, CaptureError>;

/// Owned frame data
#[derive(Clone)]
pub struct FrameData {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

/// Manages a scap Capturer and maintains the last captured frame
pub struct FrameSource {
    last_frame: Arc<parking_lot::RwLock<Option<Arc<FrameData>>>>,
    frame_ready: Arc<Notify>,
    _thread_handle: Option<std::thread::JoinHandle<()>>,
}

impl FrameSource {
    /// Create a new FrameSource from a preconfigured scap Capturer
    pub fn new(mut capturer: ScapCapturer) -> Self {
        let last_frame = Arc::new(parking_lot::RwLock::new(None));
        let last_frame_clone = Arc::clone(&last_frame);
        let frame_ready = Arc::new(Notify::new());
        let frame_ready_clone = Arc::clone(&frame_ready);

        // Start capture
        capturer.start_capture();

        // Spawn thread to continuously receive frames
        let handle = std::thread::spawn(move || {
            loop {
                match capturer.get_next_frame() {
                    Ok(frame) => {
                        let frame_data = match frame {
                            Frame::Video(video_frame) => match video_frame {
                                VideoFrame::BGRA(bgra_frame) => Some(Arc::new(FrameData {
                                    width: bgra_frame.width as u32,
                                    height: bgra_frame.height as u32,
                                    data: bgra_frame.data,
                                })),
                                _ => None,
                            },
                            Frame::Audio(_) => None,
                        };

                        if let Some(frame_data) = frame_data {
                            *last_frame_clone.write() = Some(frame_data);
                            frame_ready_clone.notify_one();
                        }
                    }
                    Err(_) => {
                        // Channel closed, exit thread
                        break;
                    }
                }
            }
        });

        Self {
            last_frame,
            frame_ready,
            _thread_handle: Some(handle),
        }
    }

    /// Get the next captured frame, blocking until one is available.
    /// Resets the internal frame to None after retrieval.
    pub async fn get_next_frame(&self) -> CaptureResult<Arc<FrameData>> {
        loop {
            // Try to take the frame
            {
                let mut guard = self.last_frame.write();
                if let Some(frame) = guard.take() {
                    return Ok(frame);
                }
            }

            // No frame available, wait for notification
            self.frame_ready.notified().await;
        }
    }
}
