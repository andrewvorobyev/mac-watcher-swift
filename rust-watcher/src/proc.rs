use std::collections::HashMap;
use std::os::raw::c_void;
use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;

use cocoa::appkit::NSApplication;
use cocoa::base::{id, nil};
use core_foundation::array::CFArray;
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_graphics::display::CGDisplay;
use core_graphics::geometry::CGRect;
use core_graphics::window::{
    CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowBounds,
    kCGWindowListExcludeDesktopElements, kCGWindowListOptionAll, kCGWindowListOptionOnScreenOnly,
    kCGWindowNumber, kCGWindowOwnerName, kCGWindowOwnerPID,
};
use image::{RgbaImage, imageops};
use objc::{msg_send, sel, sel_impl};
use scap::{
    Target,
    capturer::{Capturer, Options, Resolution},
    frame::{Frame as CaptureFrame, FrameType, VideoFrame},
};

#[derive(Debug, Clone)]
struct WindowBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl WindowBounds {
    fn contains_point(&self, x: f64, y: f64) -> bool {
        x >= self.x && x <= self.x + self.width && y >= self.y && y <= self.y + self.height
    }

    fn center(&self) -> (f64, f64) {
        (self.x + self.width / 2.0, self.y + self.height / 2.0)
    }
}

#[derive(Debug, Clone)]
struct WindowMeta {
    pid: u32,
    app: String,
    bounds: Option<WindowBounds>,
}

#[derive(Debug, Clone)]
struct DisplayMeta {
    target: Target,
    bounds: WindowBounds,
    name: String,
}

#[derive(Debug, Clone, Copy)]
struct CropRect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

fn ensure_capture_ready() -> Result<(), String> {
    static NS_APP_INIT: OnceLock<()> = OnceLock::new();
    NS_APP_INIT.get_or_init(|| unsafe {
        let app: id = NSApplication::sharedApplication(nil);
        let _: () = msg_send![app, finishLaunching];
    });

    if !scap::is_supported() {
        return Err("Screen capture is not supported on this platform".into());
    }

    if !scap::has_permission() {
        if !scap::request_permission() {
            return Err("Screen recording permission was not granted".into());
        }
    }

    Ok(())
}

pub fn list_targets() -> Result<Vec<String>, String> {
    ensure_capture_ready()?;

    let targets = scap::get_all_targets();
    let window_map = build_window_owner_map()?;
    if targets.is_empty() {
        return Err("No capture targets found".into());
    }

    let descriptions: Vec<String> = targets
        .into_iter()
        .filter_map(|target| match target {
            Target::Window(window) => {
                let title = window.title.trim();
                if title.is_empty() {
                    return None;
                }

                window_map.get(&window.id).map(|meta| {
                    format!(
                        "Window '{}' (pid={}, app='{}', id={})",
                        title, meta.pid, meta.app, window.id
                    )
                })
            }
            Target::Display(display) => {
                Some(format!("Display '{}' (id={})", display.title, display.id))
            }
        })
        .collect();

    if descriptions.is_empty() {
        return Err("No titled capture targets found".into());
    }

    Ok(descriptions)
}

pub fn capture_pid_window(pid: u32, output_path: &Path) -> Result<(), String> {
    ensure_capture_ready()?;

    if pid == 0 {
        return Err("PID must be greater than zero".into());
    }

    let window_map = build_window_owner_map()?;
    eprintln!(
        "[watcher] window owner map contains {} entries",
        window_map.len()
    );

    let targets = scap::get_all_targets();
    eprintln!("[watcher] fetched {} capture targets", targets.len());

    let mut display_candidates: Vec<DisplayMeta> = Vec::new();
    let mut selected_window: Option<(String, u32, WindowMeta)> = None;

    for target in targets.into_iter() {
        match &target {
            Target::Window(window) => {
                if let Some(meta) = window_map.get(&window.id) {
                    if meta.pid == pid {
                        eprintln!(
                            "[watcher] matched PID {} with window '{}' (id={}) owned by {}",
                            pid, window.title, window.id, meta.app
                        );
                        selected_window = Some((window.title.clone(), window.id, meta.clone()));
                    }
                }
            }
            Target::Display(display) => {
                if let Some(bounds) = display_bounds(display) {
                    display_candidates.push(DisplayMeta {
                        target: target.clone(),
                        bounds,
                        name: display.title.clone(),
                    });
                }
            }
        }
    }

    let (window_title, window_id, window_meta) = selected_window.ok_or_else(|| {
        eprintln!("[watcher] no window target matched PID {}", pid);
        format!("No captureable window found for PID {}", pid)
    })?;

    let window_bounds = window_meta
        .bounds
        .ok_or_else(|| format!("No bounds information for window id {}", window_id))?;

    if display_candidates.is_empty() {
        return Err("No display targets available for capture".into());
    }

    let (center_x, center_y) = window_bounds.center();
    let display_meta = display_candidates
        .iter()
        .find(|candidate| candidate.bounds.contains_point(center_x, center_y))
        .cloned()
        .or_else(|| display_candidates.first().cloned())
        .ok_or_else(|| "Unable to determine display for window".to_string())?;

    eprintln!(
        "[watcher] capturing display '{}' for window '{}' (id={})",
        display_meta.name, window_title, window_id
    );

    let mut options = Options::default();
    options.fps = 30;
    options.show_cursor = false;
    options.show_highlight = false;
    options.target = Some(display_meta.target.clone());
    options.output_type = FrameType::BGRAFrame;
    options.output_resolution = Resolution::Captured;
    options.captures_audio = false;

    let mut capturer = Capturer::build(options).map_err(|err| {
        eprintln!("[watcher] Capturer::build failed for PID {}: {}", pid, err);
        format!("Unable to start capture: {}", err)
    })?;

    capturer.start_capture();

    let frame = loop {
        match capturer.get_next_frame() {
            Ok(CaptureFrame::Video(VideoFrame::BGRA(frame))) => break frame,
            Ok(CaptureFrame::Video(_)) => continue,
            Ok(CaptureFrame::Audio(_)) => continue,
            Err(err) => {
                capturer.stop_capture();
                eprintln!("[watcher] error receiving frame: {}", err);
                return Err(format!("Failed to receive frame: {}", err));
            }
        }
    };

    capturer.stop_capture();
    eprintln!(
        "[watcher] captured BGRA frame {}x{} for PID {}",
        frame.width, frame.height, pid
    );

    if frame.width <= 0 || frame.height <= 0 {
        return Err("Captured frame dimensions were invalid".into());
    }

    let frame_width = frame.width as u32;
    let frame_height = frame.height as u32;
    let mut data = frame.data;

    for pixel in data.chunks_exact_mut(4) {
        pixel.swap(0, 2);
    }

    let image = RgbaImage::from_vec(frame_width, frame_height, data)
        .ok_or_else(|| "Captured frame data had unexpected length".to_string())?;

    let crop = compute_crop_rect(
        &display_meta.bounds,
        &window_bounds,
        frame_width,
        frame_height,
    )?;
    eprintln!(
        "[watcher] cropping captured frame at x={} y={} width={} height={}",
        crop.x, crop.y, crop.width, crop.height
    );

    let cropped = imageops::crop_imm(&image, crop.x, crop.y, crop.width, crop.height).to_image();
    cropped
        .save(output_path)
        .map_err(|err| format!("Failed to save screenshot: {}", err))
}

fn build_window_owner_map() -> Result<HashMap<u32, WindowMeta>, String> {
    let options = kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
    let fallback_options = kCGWindowListOptionAll;

    let array_ref = unsafe { CGWindowListCopyWindowInfo(options, kCGNullWindowID) };
    let array_ref = if array_ref.is_null() {
        unsafe { CGWindowListCopyWindowInfo(fallback_options, kCGNullWindowID) }
    } else {
        array_ref
    };

    if array_ref.is_null() {
        return Err("CGWindowListCopyWindowInfo returned NULL".into());
    }

    let info: CFArray<CFDictionary> = unsafe { CFArray::wrap_under_create_rule(array_ref) };

    let mut map = HashMap::with_capacity(info.len() as usize);

    for dict_ref in info.iter() {
        let dict = &*dict_ref;

        let window_id = dict_number_to_u32(dict, unsafe { kCGWindowNumber } as *const c_void);
        let owner_pid = dict_number_to_u32(dict, unsafe { kCGWindowOwnerPID } as *const c_void);
        let owner_name = dict_string(dict, unsafe { kCGWindowOwnerName } as *const c_void)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let bounds = dict_window_bounds(dict);

        if let (Some(window_id), Some(owner_pid), Some(owner_name)) =
            (window_id, owner_pid, owner_name)
        {
            map.entry(window_id).or_insert(WindowMeta {
                pid: owner_pid,
                app: owner_name,
                bounds,
            });
        }
    }

    Ok(map)
}

fn dict_number_to_u32(dict: &CFDictionary, key: *const c_void) -> Option<u32> {
    let cf_value = dict_cf_type(dict, key)?;
    let number = cf_value.downcast::<CFNumber>()?;
    number.to_i64().map(|n| n as u32)
}

fn dict_string(dict: &CFDictionary, key: *const c_void) -> Option<String> {
    let cf_value = dict_cf_type(dict, key)?;
    let value = cf_value.downcast::<CFString>()?;
    Some(value.to_string())
}

fn dict_cf_type(dict: &CFDictionary, key: *const c_void) -> Option<CFType> {
    dict.find(key).map(|value| unsafe {
        let raw = *value as CFTypeRef;
        CFType::wrap_under_get_rule(raw)
    })
}

fn dict_window_bounds(dict: &CFDictionary) -> Option<WindowBounds> {
    let cf_value = dict_cf_type(dict, unsafe { kCGWindowBounds } as *const c_void)?;
    let bounds_dict = cf_value.downcast::<CFDictionary>()?;
    let rect = CGRect::from_dict_representation(&bounds_dict)?;
    Some(WindowBounds {
        x: rect.origin.x as f64,
        y: rect.origin.y as f64,
        width: rect.size.width as f64,
        height: rect.size.height as f64,
    })
}

fn display_bounds(display: &scap::Display) -> Option<WindowBounds> {
    let cg_display = CGDisplay::new(display.raw_handle.0);
    let rect = cg_display.bounds();
    if rect.size.width == 0.0 || rect.size.height == 0.0 {
        return None;
    }

    Some(WindowBounds {
        x: rect.origin.x as f64,
        y: rect.origin.y as f64,
        width: rect.size.width as f64,
        height: rect.size.height as f64,
    })
}

fn compute_crop_rect(
    display_bounds: &WindowBounds,
    window_bounds: &WindowBounds,
    frame_width: u32,
    frame_height: u32,
) -> Result<CropRect, String> {
    if display_bounds.width <= 0.0 || display_bounds.height <= 0.0 {
        return Err("Display bounds reported zero size".into());
    }

    let frame_width_i32 = frame_width as i32;
    let frame_height_i32 = frame_height as i32;

    let scale_x = frame_width as f64 / display_bounds.width;
    let scale_y = frame_height as f64 / display_bounds.height;

    let rel_x = window_bounds.x - display_bounds.x;
    let rel_y = window_bounds.y - display_bounds.y;

    let mut crop_x = (rel_x * scale_x).round() as i32;
    let mut crop_width = (window_bounds.width * scale_x).round() as i32;
    let bottom_offset = (rel_y * scale_y).round() as i32;
    let mut crop_height = (window_bounds.height * scale_y).round() as i32;
    let mut crop_y = frame_height_i32 - bottom_offset - crop_height;

    if crop_width <= 0 || crop_height <= 0 {
        return Err("Calculated crop dimensions were non-positive".into());
    }

    if crop_x < 0 {
        crop_width += crop_x;
        crop_x = 0;
    }
    if crop_y < 0 {
        crop_height += crop_y;
        crop_y = 0;
    }

    if crop_width <= 0 || crop_height <= 0 {
        return Err("Crop rectangle fell outside capture frame".into());
    }

    if crop_x + crop_width > frame_width_i32 {
        crop_width = frame_width_i32 - crop_x;
    }
    if crop_y + crop_height > frame_height_i32 {
        crop_height = frame_height_i32 - crop_y;
    }

    if crop_width <= 0 || crop_height <= 0 {
        return Err("Adjusted crop rectangle was empty".into());
    }

    Ok(CropRect {
        x: crop_x as u32,
        y: crop_y as u32,
        width: crop_width as u32,
        height: crop_height as u32,
    })
}

pub fn resolve_app_name(pid: u32) -> Result<String, String> {
    if pid == 0 {
        return Err("PID must be greater than zero".into());
    }

    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .output()
        .map_err(|err| format!("Unable to execute ps: {}", err))?;

    if !output.status.success() {
        return Err(format!(
            "ps returned a non-zero exit status for PID {}",
            pid
        ));
    }

    let command_path = String::from_utf8(output.stdout)
        .map_err(|_| "ps output was not valid UTF-8".to_string())?
        .trim()
        .to_string();

    if command_path.is_empty() {
        return Err("No process found for the provided PID".into());
    }

    let app_name = Path::new(&command_path)
        .file_stem()
        .or_else(|| Path::new(&command_path).file_name())
        .and_then(|name| name.to_str())
        .map(|name| name.to_string())
        .ok_or_else(|| "Unable to determine application name".to_string())?;

    Ok(app_name)
}
