use std::path::Path;
use std::process::Command;

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
    if targets.is_empty() {
        return Err("No capture targets found".into());
    }

    let descriptions = targets
        .into_iter()
        .map(|target| match target {
            scap::Target::Window(window) => {
                let title = if window.title.trim().is_empty() {
                    "<untitled>".to_string()
                } else {
                    window.title.clone()
                };
                format!("Window '{}' (id={})", title, window.id)
            }
            scap::Target::Display(display) => {
                format!("Display '{}' (id={})", display.title, display.id)
            }
        })
        .collect();

    Ok(descriptions)
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
        return Err(format!("ps returned a non-zero exit status for PID {}", pid));
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
        return Err(format!("osascript did not return a window id for PID {}", pid));
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
