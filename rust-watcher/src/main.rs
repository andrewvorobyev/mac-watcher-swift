#[cfg(not(target_os = "macos"))]
compile_error!("watcher currently supports only macOS builds.");

mod proc;

use clap::Parser;
use std::fs;
use std::path::Path;

#[derive(Parser, Debug)]
#[command(about = "Resolve a process ID to its application name", version, author)]
struct Cli {
    /// Numeric process identifier (PID) to inspect
    pid: u32,
}

fn main() {
    let args = Cli::parse();

    let name = match proc::resolve_app_name(args.pid) {
        Ok(name) => {
            println!("{}", name);
            name
        }
        Err(err) => {
            eprintln!("Failed to resolve PID {}: {}", args.pid, err);
            std::process::exit(1);
        }
    };

    match proc::list_targets() {
        Ok(targets) => {
            println!("Discovered capture targets:");
            for target in targets {
                println!("  - {}", target);
            }
        }
        Err(err) => {
            eprintln!("Unable to list capture targets: {}", err);
        }
    }

    let output_dir = Path::new("output");
    if let Err(err) = fs::create_dir_all(output_dir) {
        eprintln!("Unable to create output directory: {}", err);
        std::process::exit(1);
    }

    let screenshot_path = output_dir.join(format!("{}.png", name));

    if let Err(err) = proc::capture_window_screenshot(args.pid, &screenshot_path) {
        eprintln!("Failed to capture screenshot: {}", err);
        std::process::exit(1);
    }

    println!("Saved screenshot to {}", screenshot_path.display());
}
