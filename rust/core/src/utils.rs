use std::fs;
use std::io;
use std::path::Path;

/// Ensures a directory exists and is empty.
/// If the directory exists, all its contents are removed.
/// If it doesn't exist, it is created.
pub fn ensure_clean_directory<P: AsRef<Path>>(path: P) -> io::Result<()> {
    let path = path.as_ref();

    if path.exists() {
        // Remove the directory and all its contents
        fs::remove_dir_all(path)?;
    }

    // Create the directory
    fs::create_dir_all(path)?;

    Ok(())
}
