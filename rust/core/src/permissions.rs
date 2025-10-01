use thiserror::Error;

#[derive(Debug, Error)]
pub enum PermissionError {
    #[error("Platform not supported")]
    PlatformNotSupported,
    #[error("Permission not granted")]
    PermissionDenied,
}

pub type PermissionResult<T> = std::result::Result<T, PermissionError>;

/// Checks and requests screen recording permission
pub fn ensure_screen_recording_permission() -> PermissionResult<()> {
    // Check if platform is supported
    if !scap::is_supported() {
        return Err(PermissionError::PlatformNotSupported);
    }

    // Check if we have permission
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
            return Ok(());
        } else {
            return Err(PermissionError::PermissionDenied);
        }
    }

    Ok(())
}
