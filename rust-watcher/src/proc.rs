use std::collections::HashMap;
use std::os::raw::c_void;
use std::path::Path;
use std::process::Command;

use core_foundation::array::CFArray;
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_graphics::window::{
    CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowListExcludeDesktopElements,
    kCGWindowListOptionAll, kCGWindowListOptionOnScreenOnly, kCGWindowNumber, kCGWindowOwnerName,
    kCGWindowOwnerPID,
};

pub fn list_targets() -> Result<Vec<String>, String> {
    if !scap::is_supported() {
        return Err("Screen capture is not supported on this platform".into());
    }

    if !scap::has_permission() {
        if !scap::request_permission() {
            return Err("Screen recording permission was not granted".into());
        }
    }

    let targets = scap::get_all_targets();
    let window_map = build_window_owner_map()?;
    if targets.is_empty() {
        return Err("No capture targets found".into());
    }

    let descriptions: Vec<String> = targets
        .into_iter()
        .filter_map(|target| match target {
            scap::Target::Window(window) => {
                let title = window.title.trim();
                if title.is_empty() {
                    return None;
                }

                window_map.get(&window.id).map(|(pid, app)| {
                    format!(
                        "Window '{}' (pid={}, app='{}', id={})",
                        title, pid, app, window.id
                    )
                })
            }
            scap::Target::Display(display) => {
                Some(format!("Display '{}' (id={})", display.title, display.id))
            }
        })
        .collect();

    if descriptions.is_empty() {
        return Err("No titled capture targets found".into());
    }

    Ok(descriptions)
}

fn build_window_owner_map() -> Result<HashMap<u32, (u32, String)>, String> {
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
            map.entry(window_id).or_insert((owner_pid, owner_name));
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

pub fn capture_window_screenshot(pid: u32, output_path: &Path) -> Result<(), String> {
    let script = format!(
        "tell application \"System Events\"\n    tell (first application process whose unix id is {})\n        value of attribute \"AXWindowNumber\" of first window\n    end tell\nend tell",
        pid
    );

    let osa_output = Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .output()
        .map_err(|err| format!("Failed to run osascript: {}", err))?;

    if !osa_output.status.success() {
        let stderr = String::from_utf8_lossy(&osa_output.stderr);
        return Err(format!(
            "Unable to determine window for PID {}: {}",
            pid,
            stderr.trim()
        ));
    }

    let window_id_str = String::from_utf8(osa_output.stdout)
        .map_err(|_| "osascript returned non-UTF-8 output".to_string())?
        .trim()
        .to_string();

    if window_id_str.is_empty() {
        return Err(format!(
            "osascript did not return a window id for PID {}",
            pid
        ));
    }

    let capture_output = Command::new("/usr/sbin/screencapture")
        .arg("-x")
        .arg("-l")
        .arg(&window_id_str)
        .arg(output_path)
        .output()
        .map_err(|err| format!("Failed to run screencapture: {}", err))?;

    if !capture_output.status.success() {
        let stderr = String::from_utf8_lossy(&capture_output.stderr);
        return Err(format!(
            "screencapture failed for window {}: {}",
            window_id_str,
            stderr.trim()
        ));
    }

    Ok(())
}
