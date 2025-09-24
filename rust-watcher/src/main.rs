#[cfg(not(target_os = "macos"))]
compile_error!("watcher currently supports only macOS builds.");

mod proc;

use clap::Parser;
use std::fs;
use std::path::Path;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Parser, Debug)]
#[command(
    about = "Resolve a process ID to its application name",
    version,
    author
)]
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

    let mut capture_target = match proc::prepare_window_capture(args.pid) {
        Ok(target) => {
            println!(
                "Tracking PID {} window '{}' (id={}) owned by {}",
                target.pid, target.window_title, target.window_id, target.app_name
            );
            target
        }
        Err(err) => {
            eprintln!("Unable to prepare capture: {}", err);
            std::process::exit(1);
        }
    };

    println!("Beginning capture loop. Press Ctrl+C to stop.");

    loop {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let screenshot_path = output_dir.join(format!("{}-{}.png", name, timestamp));

        match proc::capture_window(capture_target.window_id, &screenshot_path) {
            Ok(()) => println!("Saved screenshot to {}", screenshot_path.display()),
            Err(err) => {
                eprintln!(
                    "Capture failed for window {} (id={}): {}",
                    capture_target.window_title, capture_target.window_id, err
                );

                match proc::prepare_window_capture(args.pid) {
                    Ok(new_target) => {
                        println!(
                            "Re-acquired PID {} window '{}' (id={})",
                            new_target.pid, new_target.window_title, new_target.window_id
                        );
                        capture_target = new_target;
                        continue;
                    }
                    Err(prepare_err) => {
                        eprintln!("Unable to re-acquire window: {}", prepare_err);
                    }
                }
            }
        }

        thread::sleep(Duration::from_secs(1));
    }
}
