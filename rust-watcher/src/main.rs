#[cfg(not(target_os = "macos"))]
compile_error!("watcher currently supports only macOS builds.");

mod proc;

use clap::Parser;

#[derive(Parser, Debug)]
#[command(about = "Resolve a process ID to its application name", version, author)]
struct Cli {
    /// Numeric process identifier (PID) to inspect
    pid: u32,
}

fn main() {
    let args = Cli::parse();

    match proc::resolve_app_name(args.pid) {
        Ok(name) => println!("{}", name),
        Err(err) => {
            eprintln!("Failed to resolve PID {}: {}", args.pid, err);
            std::process::exit(1);
        }
    }
}
