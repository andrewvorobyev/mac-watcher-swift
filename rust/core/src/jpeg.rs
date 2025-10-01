use image::{ImageBuffer, ImageError, RgbaImage};
use std::io::Cursor;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum JpegError {
    #[error("Image encoding error: {0}")]
    ImageError(#[from] ImageError),
    #[error("Invalid buffer dimensions")]
    InvalidDimensions,
}

pub type JpegResult<T> = std::result::Result<T, JpegError>;

/// Encodes BGRA raw image data to JPEG format and saves to a file
///
/// # Arguments
/// * `bgra_data` - Raw BGRA pixel data (4 bytes per pixel)
/// * `width` - Image width in pixels
/// * `height` - Image height in pixels
/// * `path` - Output file path
/// * `quality` - JPEG quality (1-100, where 100 is best quality)
pub fn encode_bgra_to_jpeg<P: AsRef<Path>>(
    bgra_data: &[u8],
    width: u32,
    height: u32,
    path: P,
    _quality: u8,
) -> JpegResult<()> {
    // Verify buffer size
    let expected_size = (width * height * 4) as usize;
    if bgra_data.len() != expected_size {
        return Err(JpegError::InvalidDimensions);
    }

    // Convert BGRA to RGBA
    let mut rgba_data = Vec::with_capacity(bgra_data.len());
    for chunk in bgra_data.chunks_exact(4) {
        rgba_data.push(chunk[2]); // R (was B)
        rgba_data.push(chunk[1]); // G
        rgba_data.push(chunk[0]); // B (was R)
        rgba_data.push(chunk[3]); // A
    }

    // Create image buffer
    let img: RgbaImage = ImageBuffer::from_raw(width, height, rgba_data)
        .ok_or(JpegError::InvalidDimensions)?;

    // Convert to RGB (JPEG doesn't support alpha)
    let rgb_img = image::DynamicImage::ImageRgba8(img).to_rgb8();

    // Save as JPEG
    rgb_img.save_with_format(path, image::ImageFormat::Jpeg)?;

    Ok(())
}

/// Encodes BGRA raw image data to JPEG format and returns as bytes
///
/// # Arguments
/// * `bgra_data` - Raw BGRA pixel data (4 bytes per pixel)
/// * `width` - Image width in pixels
/// * `height` - Image height in pixels
/// * `quality` - JPEG quality (1-100, where 100 is best quality)
pub fn encode_bgra_to_jpeg_bytes(
    bgra_data: &[u8],
    width: u32,
    height: u32,
    _quality: u8,
) -> JpegResult<Vec<u8>> {
    // Verify buffer size
    let expected_size = (width * height * 4) as usize;
    if bgra_data.len() != expected_size {
        return Err(JpegError::InvalidDimensions);
    }

    // Convert BGRA to RGBA
    let mut rgba_data = Vec::with_capacity(bgra_data.len());
    for chunk in bgra_data.chunks_exact(4) {
        rgba_data.push(chunk[2]); // R (was B)
        rgba_data.push(chunk[1]); // G
        rgba_data.push(chunk[0]); // B (was R)
        rgba_data.push(chunk[3]); // A
    }

    // Create image buffer
    let img: RgbaImage = ImageBuffer::from_raw(width, height, rgba_data)
        .ok_or(JpegError::InvalidDimensions)?;

    // Convert to RGB (JPEG doesn't support alpha)
    let rgb_img = image::DynamicImage::ImageRgba8(img).to_rgb8();

    // Encode to JPEG bytes
    let mut buffer = Cursor::new(Vec::new());
    rgb_img.write_to(&mut buffer, image::ImageFormat::Jpeg)?;

    Ok(buffer.into_inner())
}
