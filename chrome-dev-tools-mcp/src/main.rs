use rmcp::{
    model::CallToolRequestParam,
    service::QuitReason,
    transport::{ConfigureCommandExt, TokioChildProcess},
    ServiceExt,
};
use serde_json::json;
use tokio::{pin, process::Command, signal};

const TARGET_TOOL: &str = "list_pages";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Launching Chrome DevTools MCP server...");

    let running_service = ()
        .serve(TokioChildProcess::new(Command::new("npx").configure(
            |cmd| {
                cmd.arg("chrome-devtools-mcp@latest");
                cmd.kill_on_drop(true);
            },
        ))?)
        .await?;

    println!("Chrome DevTools MCP server launched. Press Ctrl+C to stop.");

    let tools = running_service.list_all_tools().await?;
    if tools.is_empty() {
        println!("Server reported no tools.");
    } else {
        println!("Tools exposed by the server:");
        for tool in &tools {
            let summary = tool.title.as_deref().or(tool.description.as_deref());
            match summary {
                Some(text) => println!("- {} — {}", tool.name, text),
                None => println!("- {}", tool.name),
            }
        }
    }

    if tools.iter().any(|tool| tool.name == TARGET_TOOL) {
        println!("\nCalling `{TARGET_TOOL}`...");
        match running_service
            .call_tool(CallToolRequestParam {
                name: TARGET_TOOL.into(),
                arguments: Some(json!({}).as_object().cloned().unwrap_or_default()),
            })
            .await
        {
            Ok(result) => match serde_json::to_string_pretty(&result) {
                Ok(rendered) => println!("Tool result:\n{rendered}"),
                Err(err) => println!(
                    "Tool returned result but formatting as JSON failed: {err}\n{result:#?}"
                ),
            },
            Err(err) => println!("Tool call failed: {err}"),
        }
    } else {
        println!("\nTool `{TARGET_TOOL}` not found on this server.");
    }

    let cancel_token = running_service.cancellation_token();
    let wait_future = running_service.waiting();
    pin!(wait_future);

    let quit_result = tokio::select! {
        result = &mut wait_future => {
            println!("Chrome DevTools MCP server exited unexpectedly.");
            result
        }
        _ = signal::ctrl_c() => {
            println!("Ctrl+C received. Shutting down Chrome DevTools MCP server...");
            cancel_token.cancel();
            wait_future.await
        }
    };

    match quit_result {
        Ok(QuitReason::Cancelled) => println!("Chrome DevTools MCP server stopped."),
        Ok(reason) => println!("Chrome DevTools MCP server stopped: {reason:?}"),
        Err(err) => eprintln!("Failed to join MCP server task: {err}"),
    }

    Ok(())
}
