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
use core_graphics::base::{kCGBitmapByteOrder32Big, kCGImageAlphaPremultipliedLast};
use core_graphics::color_space::CGColorSpace;
use core_graphics::context::CGContext;
use core_graphics::geometry::{CGPoint, CGRect, CGSize};
use core_graphics::image::CGImage;
use core_graphics::window::{
    CGWindowListCopyWindowInfo, create_image, kCGNullWindowID, kCGWindowImageBestResolution,
    kCGWindowImageBoundsIgnoreFraming, kCGWindowImageDefault, kCGWindowListExcludeDesktopElements,
    kCGWindowListOptionAll, kCGWindowListOptionIncludingWindow, kCGWindowListOptionOnScreenOnly,
    kCGWindowNumber, kCGWindowOwnerName, kCGWindowOwnerPID,
};
use image::RgbaImage;
use objc::{msg_send, sel, sel_impl};
use scap::Target;

#[derive(Debug, Clone)]
struct WindowMeta {
    pid: u32,
    app: String,
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

    let mut selected_window: Option<(String, u32, WindowMeta)> = None;

    for target in targets.into_iter() {
        if let Target::Window(window) = target {
            if let Some(meta) = window_map.get(&window.id) {
                if meta.pid == pid {
                    eprintln!(
                        "[watcher] matched PID {} with window '{}' (id={}) owned by {}",
                        pid, window.title, window.id, meta.app
                    );
                    selected_window = Some((window.title.clone(), window.id, meta.clone()));
                    break;
                }
            }
        }
    }

    let (window_title, window_id, window_meta) = selected_window.ok_or_else(|| {
        eprintln!("[watcher] no window target matched PID {}", pid);
        format!("No captureable window found for PID {}", pid)
    })?;

    let image = capture_window_image(window_id)?;
    eprintln!(
        "[watcher] captured window '{}' (pid={}, app='{}', id={})",
        window_title, pid, window_meta.app, window_id
    );

    image
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

        if let (Some(window_id), Some(owner_pid), Some(owner_name)) =
            (window_id, owner_pid, owner_name)
        {
            map.entry(window_id).or_insert(WindowMeta {
                pid: owner_pid,
                app: owner_name,
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

fn capture_window_image(window_id: u32) -> Result<RgbaImage, String> {
    let rect = CGRect::new(&CGPoint::new(0.0, 0.0), &CGSize::new(0.0, 0.0));
    let image = create_image(
        rect,
        kCGWindowListOptionIncludingWindow,
        window_id,
        kCGWindowImageDefault | kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution,
    )
    .ok_or_else(|| format!("Unable to capture window image for id {}", window_id))?;

    cgimage_to_rgba(&image)
}

fn cgimage_to_rgba(image: &CGImage) -> Result<RgbaImage, String> {
    let width = image.width();
    let height = image.height();

    if width == 0 || height == 0 {
        return Err("Captured window image had zero dimensions".into());
    }

    let color_space = CGColorSpace::create_device_rgb();
    let bytes_per_row = width * 4;

    let mut context = CGContext::create_bitmap_context(
        None,
        width,
        height,
        8,
        bytes_per_row,
        &color_space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
    );

    let draw_rect = CGRect::new(
        &CGPoint::new(0.0, 0.0),
        &CGSize::new(width as f64, height as f64),
    );
    context.draw_image(draw_rect, image);

    let data = context.data().to_vec();
    RgbaImage::from_vec(width as u32, height as u32, data)
        .ok_or_else(|| "Failed to convert captured window image".to_string())
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
