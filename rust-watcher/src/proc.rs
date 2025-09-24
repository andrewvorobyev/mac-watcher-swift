pub fn resolve_app_name(pid: u32) -> Result<String, String> {
    use std::path::Path;
    use std::process::Command;

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
