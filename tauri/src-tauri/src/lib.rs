//! shed-desktop (Tauri) — a real Linux client toward Mac parity, on the shared
//! shed-core. Runs on Linux (WebKitGTK, the shipped target) and macOS (WKWebView,
//! the dev / UI-comparison loop vs the SwiftUI app).
//!
//! Thin entry: resolve the `SHED_TAURI_*` env, take the single-instance flock,
//! and in `setup` bind the JSON IPC server (the drivability North Star) on Tauri's
//! async runtime before the window paints — so a harness `identify` right after
//! launch succeeds.

mod approval;
mod env;
mod ipc;
mod prefs;
mod screenshot;
mod single_instance;
mod state;
mod termctl;
mod tray;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use env::Env;
use ipc::{Handler, IpcServer};
use shed_app::traits::{AuthGateRef, NotifierRef};
use shed_app::{
    AlwaysApprovedGate, AuditStore, Backend, Coordinator, CoordinatorDeps, FakeNotifier,
    HelloClientInfo, HostAgentClient, HostAgentTokenMinter, SshPrefs,
};
use shed_core::approval::{
    ApprovalChoice, ApprovalDecision, ApprovalMethod, ApprovalScope, SshApprovalPolicy,
};
use shed_core::models::CreateShedRequest;
use shed_core::token::TokenMinter;
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

/// The configured hosts a create can target (the New-Shed dialog's picker) — even
/// hosts with no sheds yet, unlike the sidebar's sheds-derived list.
#[tauri::command]
fn list_hosts(backend: tauri::State<'_, Arc<Backend>>) -> Vec<String> {
    backend.host_names()
}

// -- create (the New-Shed dialog; the harness drives the parallel create.* ops) --

/// The New-Shed dialog's form (`vm_backend` avoids clashing with the shed backend).
#[derive(serde::Deserialize)]
struct CreateForm {
    name: String,
    host: Option<String>,
    image: Option<String>,
    vm_backend: Option<String>,
    cpus: Option<i64>,
    memory_mb: Option<i64>,
    repo: Option<String>,
}

/// Kick off a create; returns the id the dialog polls via `create_status`. The
/// SSE stream runs on Tauri's tokio runtime.
#[tauri::command]
async fn create_start(
    backend: tauri::State<'_, Arc<Backend>>,
    form: CreateForm,
) -> Result<String, String> {
    let req = CreateShedRequest {
        name: form.name,
        repo: form.repo,
        local_dir: None,
        image: form.image,
        backend: form.vm_backend,
        cpus: form.cpus,
        memory_mb: form.memory_mb,
        no_provision: None,
    };
    backend
        .create_start(
            &tokio::runtime::Handle::current(),
            form.host.as_deref(),
            req,
        )
        .map_err(|e| e.to_string())
}

/// The in-flight create's progress snapshot (`{id,state,messages,shed,error}`), or
/// `{state:"unknown"}` once it's cancelled/gone.
#[tauri::command]
fn create_status(backend: tauri::State<'_, Arc<Backend>>, create_id: String) -> serde_json::Value {
    backend
        .create_status(&create_id)
        .map(|p| serde_json::json!(p))
        .unwrap_or_else(|| serde_json::json!({ "state": "unknown" }))
}

/// Abort a create's stream + drop its state (idempotent).
#[tauri::command]
fn create_cancel(backend: tauri::State<'_, Arc<Backend>>, create_id: String) {
    backend.create_cancel(&create_id);
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

// -- terminal + prefs commands (the frontend Preferences view + the shed-card
//    "Open in Terminal" button; the same TerminalCtl the IPC ops use) -----------

/// The offerable terminal presets + install detection (the picker's source).
#[tauri::command]
fn terminal_presets(terminal: tauri::State<'_, termctl::SharedTerminal>) -> serde_json::Value {
    terminal.presets()
}

/// The persisted prefs (seeds the Preferences view).
#[tauri::command]
fn get_prefs(terminal: tauri::State<'_, termctl::SharedTerminal>) -> serde_json::Value {
    terminal.prefs_get()
}

/// Persist the chosen terminal preset (+ optional custom template).
#[tauri::command]
fn set_terminal_pref(
    terminal: tauri::State<'_, termctl::SharedTerminal>,
    preset: String,
    template: Option<String>,
) -> Result<(), String> {
    terminal
        .prefs_set_terminal(&preset, template)
        .map(|_| ())
        .map_err(|(_code, msg)| msg)
}

/// Open a shed in the user's chosen terminal (the persisted pref). Gated off in
/// test mode — the button never spawns under the harness.
#[tauri::command]
fn open_terminal(
    terminal: tauri::State<'_, termctl::SharedTerminal>,
    env: tauri::State<'_, Env>,
    shed: String,
    host: Option<String>,
    session: Option<String>,
) -> Result<(), String> {
    if env.test_mode {
        return Err("terminal.open is disabled in test mode (use terminal.preview)".to_string());
    }
    terminal
        .open(host.as_deref(), &shed, session.as_deref(), None, None)
        .map(|_| ())
        .map_err(|(_code, msg)| msg)
}

// -- approvals (the frontend Approvals/Activity panes + approval prefs) --------

/// The pending approval cards (each with gate + scope/TTL defaults). The pane
/// re-fetches on the `approvals-changed` event (see TauriEventSink).
#[tauri::command]
async fn approvals_list(
    coordinator: tauri::State<'_, Coordinator>,
) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!(coordinator.approvals_list().await))
}

/// Approve/deny a pending request (the card's buttons). Tauri deserializes the
/// enum args from their wire strings ("approve"|"deny", "per-request"|…) via serde.
#[tauri::command]
async fn approval_decide(
    coordinator: tauri::State<'_, Coordinator>,
    id: String,
    decision: ApprovalDecision,
    scope: Option<ApprovalScope>,
    ttl: Option<String>,
    persist: Option<bool>,
) -> Result<(), String> {
    coordinator
        .decide_approval(
            id,
            ApprovalChoice {
                decision,
                scope,
                ttl,
                persist: persist.unwrap_or(false),
            },
        )
        .await;
    Ok(())
}

/// The merged audit feed (most-recent-first). Re-fetched on `activity-changed`.
#[tauri::command]
async fn activity_list(
    coordinator: tauri::State<'_, Coordinator>,
    limit: Option<usize>,
) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!(coordinator.activity_list(limit.unwrap_or(200)).await))
}

/// The namespaces the host agent delegates to us (drives which approval-prefs
/// sections show + the "host agent · connected" indicator).
#[tauri::command]
async fn gate_namespaces(coordinator: tauri::State<'_, Coordinator>) -> Result<Vec<String>, String> {
    Ok(coordinator.gate_namespaces().await)
}

/// Apply SSH approval prefs (method/policy/TTL) + re-evaluate the pending queue.
/// Tauri deserializes the enum args from their wire strings via serde.
#[tauri::command]
async fn set_ssh_approval(
    coordinator: tauri::State<'_, Coordinator>,
    method: Option<ApprovalMethod>,
    policy: Option<SshApprovalPolicy>,
    ttl: Option<String>,
) -> Result<(), String> {
    coordinator.set_ssh_approval(method, policy, ttl).await;
    Ok(())
}

/// The current SSH approval prefs (`{method, policy, ttl}`) — drives the
/// Preferences dropdown so it reflects the running coordinator, not a guess.
#[tauri::command]
async fn ssh_prefs_get(
    coordinator: tauri::State<'_, Coordinator>,
) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!(coordinator.ssh_prefs().await))
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

    // The host-agent connection (approvals + the all-namespace audit feed) + the
    // control-token minter it backs. Construct BEFORE the Backend so each secure
    // (non-mock) server's client mints its bearer via the agent's token.get (C2;
    // fail-closed on a mint failure). The client CONNECTS in `setup`.
    let clock = shed_app::traits::system_clock();
    let host = HostAgentClient::new(env.host_agent_socket.clone(), clock.clone());
    // Minting is for real (non-mock) servers only — the hermetic mock is tokenless.
    let minter: Option<Arc<dyn TokenMinter>> = env
        .mock_base_url
        .is_none()
        .then(|| Arc::new(HostAgentTokenMinter::new(host.clone())) as Arc<dyn TokenMinter>);

    // One shared shed-core-backed Backend behind both surfaces: the WebView's
    // `invoke` commands (list_sheds/shed_action) and the harness's IPC ops
    // (sheds.*/shed.*/create.*). Hermetic in test mode (every host → the mock).
    let backend = Arc::new(Backend::from_env_parts_with_minter(
        env.test_mode,
        env.mock_base_url.as_deref(),
        &env.config_path,
        minter.as_ref(),
    ));

    tauri::Builder::default()
        .manage(ui.clone())
        .manage(backend.clone())
        .manage(env.clone())
        .invoke_handler(tauri::generate_handler![
            ui_report,
            list_sheds,
            list_hosts,
            shed_action,
            system_df,
            create_start,
            create_status,
            create_cancel,
            terminal_presets,
            get_prefs,
            set_terminal_pref,
            open_terminal,
            approvals_list,
            approval_decide,
            activity_list,
            gate_namespaces,
            set_ssh_approval,
            ssh_prefs_get
        ])
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
            // The terminal ops (preset resolution, launch, detection, the pref),
            // shared by the IPC handler + the frontend invoke commands.
            let terminal: termctl::SharedTerminal = Arc::new(termctl::TerminalCtl::new(
                backend.clone(),
                prefs,
                scripts_dir,
            ));
            app.manage(terminal.clone());

            // The approval spine: start the host-agent connection (its event stream
            // feeds the coordinator), pick the seam impls (test-mode fakes vs the
            // prod stubs — the real native gate + notifier land in B6), spawn the
            // coordinator actor + its 1s expiry tick. The audit log lives under the
            // app data dir (redirected + hermetic in test mode).
            let hello = HelloClientInfo {
                name: "shed-desktop".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
                pid: std::process::id() as i32,
                capabilities: vec!["approval.ssh".to_string(), "event.stream".to_string()],
                replay_events: 50,
            };
            let (notifier, gate): (NotifierRef, AuthGateRef) = if env.test_mode {
                (Arc::new(FakeNotifier::new()), Arc::new(AlwaysApprovedGate))
            } else {
                // Linux: real polkit gate + libnotify notifier; other targets: the
                // fail-closed stubs (the Tauri client's native gate is Linux-only).
                approval::production_seams()
            };
            let audit = AuditStore::new(
                app.path()
                    .app_data_dir()
                    .unwrap_or_else(|_| std::path::PathBuf::from("."))
                    .join("audit.jsonl"),
            );
            let coord_clock = clock.clone();
            // Pushes coordinator changes to the webview (app.emit) so the
            // Approvals/Activity panes re-fetch reactively.
            let coord_sink: shed_app::traits::EventSinkRef =
                Arc::new(approval::TauriEventSink::new(app.handle().clone()));
            // Start the client loop + coordinator actor + expiry tick INSIDE the
            // Tauri (tokio) runtime — tokio::spawn needs a runtime context, and the
            // setup hook itself has none (the same reason the IPC bind below uses
            // block_on). The spawned tasks are detached and outlive the block.
            let coordinator = tauri::async_runtime::block_on(async move {
                let host_events = host.start(hello);
                let responder: shed_app::traits::ResponderRef = Arc::new(host);
                let coordinator = Coordinator::spawn(
                    CoordinatorDeps {
                        responder,
                        notifier,
                        gate,
                        clock: coord_clock,
                        sink: coord_sink,
                        audit,
                        ssh: SshPrefs::default(),
                        extra_rules: Vec::new(),
                        provider_modes: HashMap::new(),
                    },
                    host_events,
                );
                coordinator.start_expiry_tick();
                coordinator
            });
            app.manage(coordinator.clone());

            let handler = Handler::new(
                env.clone(),
                app.handle().clone(),
                ui.clone(),
                backend.clone(),
                terminal,
                coordinator,
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

            // The system tray (B1a). Best-effort: a headless / no-SNI host has
            // nowhere to show it, so a failure logs and the app keeps running (the
            // window is always reachable). The macOS rich popover lands in B1b.
            if let Err(e) = tray::build(app.handle()) {
                eprintln!("shed-desktop-tauri: tray unavailable ({e}); window-only");
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build shed-desktop tauri app")
        .run(|app_handle, event| match event {
            // Menu-bar/tray behavior: closing the window HIDES it (the app lives in
            // the tray); a deliberate Quit (tray → app.exit(0)) still exits.
            tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::CloseRequested { api, .. },
                ..
            } => {
                if let Some(w) = app_handle.get_webview_window(&label) {
                    let _ = w.hide();
                }
                api.prevent_close();
            }
            // An auto-exit (e.g. the last window closed) is prevented so we stay in
            // the tray; a deliberate exit carries a code and is allowed through.
            tauri::RunEvent::ExitRequested { code, api, .. } if code.is_none() => {
                api.prevent_exit();
            }
            _ => {}
        });
}
