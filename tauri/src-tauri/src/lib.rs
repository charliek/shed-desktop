//! shed-desktop (Tauri) — a real Linux client toward Mac parity, on the shared
//! shed-core. Runs on Linux (WebKitGTK, the shipped target) and macOS (WKWebView,
//! the dev / UI-comparison loop vs the SwiftUI app).
//!
//! Thin entry: resolve the `SHED_TAURI_*` env, take the single-instance flock,
//! and in `setup` bind the JSON IPC server (the drivability North Star) on Tauri's
//! async runtime before the window paints — so a harness `identify` right after
//! launch succeeds.

mod env;
mod ipc;
mod screenshot;
mod single_instance;
mod state;

use std::sync::{Arc, Mutex};

use env::Env;
use ipc::{Handler, IpcServer};
use single_instance::AcquireError;
use state::{SharedUi, UiState};

/// The React frontend reports its rendered pane + a computed-style sample here, so
/// the harness can read the real rendered state over IPC (`ui.current_pane` /
/// `ui.computed_style`). Invoked from `useUiBridge` on mount + every pane change.
#[tauri::command]
fn ui_report(ui: tauri::State<'_, SharedUi>, pane: String, style: serde_json::Value) {
    if let Ok(mut s) = ui.lock() {
        s.current_pane = Some(pane);
        s.computed_style = Some(style);
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let env = Env::from_process();

    // Single-instance: flock a pidfile (keyed to the socket's runtime dir) BEFORE
    // binding the socket, so a second launch never unlinks the live socket. On
    // contention, raise the running instance (an `app.activate` IPC) and exit.
    // Scoped to the runtime dir, so hermetic test runs don't collide — unlike an
    // identifier-scoped plugin. This flock-before-bind ordering is what makes
    // `IpcServer::bind`'s unconditional stale-socket remove safe. `_instance` holds
    // the lock (drops → releases) for the whole app run.
    let lock_path = single_instance::lock_path_for(&env.socket_path);
    let _instance = match single_instance::acquire(&lock_path) {
        Ok(lock) => Some(lock),
        Err(AcquireError::AlreadyHeld(pid)) => {
            eprintln!("shed-desktop-tauri: already running (pid {pid}); activating it");
            let _ = single_instance::activate_running_instance(&env.socket_path);
            return;
        }
        Err(AcquireError::Io(e)) => {
            // Can't determine instance state — proceed rather than block the user
            // (the flock is best-effort robustness, not a correctness gate).
            eprintln!("shed-desktop-tauri: single-instance check failed ({e}); continuing");
            None
        }
    };

    // Shared with the IPC handler so `ui.current_pane` / `ui.computed_style` read
    // what the frontend reported.
    let ui: SharedUi = Arc::new(Mutex::new(UiState::default()));

    tauri::Builder::default()
        .manage(ui.clone())
        .invoke_handler(tauri::generate_handler![ui_report])
        .setup(move |app| {
            let handler = Handler::new(env.clone(), app.handle().clone(), ui.clone());
            // block_on enters Tauri's tokio runtime so tokio's UnixListener can
            // register with the reactor; then serve on the same runtime.
            let server = tauri::async_runtime::block_on(IpcServer::bind(&env.socket_path, handler))
                .map_err(|e| {
                    format!(
                        "bind shed-desktop IPC server at {}: {e}",
                        env.socket_path.display()
                    )
                })?;
            tauri::async_runtime::spawn(async move { server.run().await });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("run shed-desktop tauri app");
}
