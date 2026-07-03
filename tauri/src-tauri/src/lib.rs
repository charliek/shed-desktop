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
mod prefs;
mod screenshot;
mod single_instance;
mod state;

use std::sync::{Arc, Mutex};

use env::Env;
use ipc::{Handler, IpcServer};
use shed_app::Backend;
use single_instance::AcquireError;
use state::{SharedUi, UiState};
use tauri::Manager;

/// The React frontend reports its rendered snapshot (`{pane, style, sheds,
/// refresh_token}`) here, so the harness reads the real rendered state over IPC
/// (`ui.current_pane` / `ui.computed_style` / `dashboard.dump`). Invoked from
/// `useUiBridge` on mount + every render. One JSON blob, not a field per op, so a
/// new reader is a key projection (see [`state::UiState`]).
#[tauri::command]
fn ui_report(ui: tauri::State<'_, SharedUi>, snapshot: serde_json::Value) {
    if let Ok(mut s) = ui.lock() {
        s.snapshot = Some(snapshot);
    }
}

/// The WebView's live shed list — `invoke("list_sheds")` on mount + on each
/// `refresh` event. Returns host-stamped sheds (all configured hosts, concurrently
/// via the shared `Backend`); the harness reads the same data via the `sheds.list`
/// IPC op.
#[tauri::command]
async fn list_sheds(backend: tauri::State<'_, Arc<Backend>>) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!(backend.list_sheds().await))
}

/// A lifecycle action from a shed card's buttons (`start`/`stop`/`reset`/`delete`).
/// The frontend re-fetches (a `sheds.refresh`) after it resolves; the harness
/// drives the same via the `shed.*` IPC ops.
#[tauri::command]
async fn shed_action(
    backend: tauri::State<'_, Arc<Backend>>,
    action: String,
    name: String,
    host: Option<String>,
) -> Result<(), String> {
    backend
        .shed_action(host.as_deref(), &name, &action)
        .await
        .map_err(|e| e.to_string())
}

/// The WebView's live per-host disk usage — `invoke("system_df")` when the System
/// pane mounts / on its Refresh. Each row is a host's `SystemDiskUsage` or the
/// error it returned (unreachable hosts are kept, not dropped). The harness reads
/// the same via the `system.df` IPC op.
#[tauri::command]
async fn system_df(backend: tauri::State<'_, Arc<Backend>>) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!(backend.system_df().await))
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

    // Shared with the IPC handler so `ui.current_pane` / `ui.computed_style` /
    // `dashboard.dump` read what the frontend reported.
    let ui: SharedUi = Arc::new(Mutex::new(UiState::default()));

    // One shared shed-core-backed Backend behind both surfaces: the WebView's
    // `invoke` commands (list_sheds/shed_action) and the harness's IPC ops
    // (sheds.*/shed.*/create.*). Hermetic in test mode (every host → the mock).
    let backend = Arc::new(Backend::from_env_parts(
        env.test_mode,
        env.mock_base_url.as_deref(),
        &env.config_path,
    ));

    tauri::Builder::default()
        .manage(ui.clone())
        .manage(backend.clone())
        .invoke_handler(tauri::generate_handler![ui_report, list_sheds, shed_action, system_df])
        .setup(move |app| {
            // The bundled terminal openers live in <resources>/bin; None in an
            // unbundled dev/test run — resolve_launch then falls back to a default
            // terminal (and terminal.open is disabled in test mode regardless).
            let scripts_dir = app
                .path()
                .resource_dir()
                .ok()
                .map(|d| d.join("bin"))
                .filter(|d| d.exists())
                .map(|d| d.to_string_lossy().into_owned());
            // Persisted prefs (terminal preset + template) in the app config dir
            // ($XDG_CONFIG_HOME/<id> on Linux; the harness redirects it, so the
            // file is hermetic in test mode).
            let prefs_path = app
                .path()
                .app_config_dir()
                .unwrap_or_else(|_| std::path::PathBuf::from("."))
                .join("prefs.json");
            let prefs: prefs::SharedPrefs = Arc::new(prefs::PrefsStore::load(prefs_path));
            let handler = Handler::new(
                env.clone(),
                app.handle().clone(),
                ui.clone(),
                backend.clone(),
                scripts_dir,
                prefs,
            );
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
