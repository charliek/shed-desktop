//! The IPC server: newline-delimited JSON over a Unix socket — the same envelope
//! the shed-desktop harness + `shedctl` speak (`{id, op, params}` in, `{id, ok,
//! result}` / `{id, ok:false, error:{code,message}}` out). Ported from
//! `shed-gtk/src/ipc.rs`. Making the app drivable + observable by an agent over
//! IPC is the North Star.
//!
//! Window/UI ops (`identify` / `ui.navigate` / `ui.show_window` / `app.activate` /
//! `app.screenshot` / the `ui.*` truth reads) go straight through the Tauri
//! `AppHandle` (its methods are thread-safe) or the shared [`SharedUi`], so —
//! unlike GTK — no main-thread marshalling channel is needed. The backend ops
//! (`sheds.*` / `shed.*` / `create.*`, A1b) run on the shared [`Backend`], and
//! `dashboard.dump` reads the sheds the frontend reported (UI truth, not a
//! backend re-query), which is why `sheds.refresh` round-trips through the
//! frontend before returning.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::runtime::Handle;

use shed_app::Backend;
use shed_core::models::CreateShedRequest;

use crate::env::Env;
use crate::state::SharedUi;
use crate::termctl::SharedTerminal;

/// A request line is tiny; cap it so a local client can't force unbounded
/// buffering with a huge/unterminated frame.
const MAX_FRAME_BYTES: usize = 1 << 20; // 1 MiB
/// Upper bound on how long `sheds.refresh` waits for the frontend to re-fetch +
/// re-report before returning anyway (best-effort — a missing/slow WebView must
/// not hang the op). The frontend round-trip is a mock HTTP fetch + a render.
const REFRESH_WAIT: Duration = Duration::from_secs(10);
/// Poll cadence while waiting for that frontend echo.
const REFRESH_POLL: Duration = Duration::from_millis(15);

/// Build an `(code, message)` error pair for the IPC error envelope.
fn err(code: &str, message: impl Into<String>) -> (String, String) {
    (code.to_string(), message.into())
}

/// A required string param, or a `bad_request` error naming the missing key — the
/// shared shape behind the shed_action/create ops' param extraction.
fn req_str<'a>(params: &'a Value, key: &str) -> Result<&'a str, (String, String)> {
    params
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| err("bad_request", format!("missing '{key}'")))
}

/// Raise + focus the main window — the shared body of `ui.show_window`,
/// `app.activate`, and the single-instance second-launch hand-off.
pub fn present_main_window<R: tauri::Runtime>(app: &AppHandle<R>) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// The `identify` payload. A free fn (not a method) so it's unit-testable without
/// a running Tauri app / `AppHandle`.
fn identify_payload(env: &Env, pid: u32) -> Value {
    json!({
        "socket_path": env.socket_path.to_string_lossy(),
        "pid": pid,
        "core": "rust",
        "platform": "tauri",
        "test_mode": env.test_mode,
        "mock_base_url": env.mock_base_url,
    })
}

/// Services one op at a time; owned by the server and shared across connections.
pub struct Handler {
    env: Env,
    app: AppHandle,
    ui: SharedUi,
    backend: Arc<Backend>,
    /// Terminal ops (preset resolution, launch, install detection, the terminal
    /// preference), shared with the frontend invoke commands.
    terminal: SharedTerminal,
    /// Monotonic token stamped onto each `sheds.refresh` so it can wait for the
    /// frontend to echo it back (a synchronous refresh — see [`Self::sheds_refresh`]).
    refresh_seq: AtomicU64,
    pid: u32,
}

impl Handler {
    pub fn new(
        env: Env,
        app: AppHandle,
        ui: SharedUi,
        backend: Arc<Backend>,
        terminal: SharedTerminal,
    ) -> Self {
        Self {
            env,
            app,
            ui,
            backend,
            terminal,
            refresh_seq: AtomicU64::new(0),
            pid: std::process::id(),
        }
    }

    /// Read + clone a key from the frontend's reported snapshot (`pane`, `style`,
    /// `sheds`, ...), or `None` if it hasn't reported / the key is absent.
    fn ui_get(&self, key: &str) -> Option<Value> {
        self.ui.lock().ok().and_then(|s| s.get(key))
    }

    /// Dispatch one op. `Ok(result)` → an `ok` envelope; `Err((code, message))` →
    /// an error envelope.
    pub async fn dispatch(&self, op: &str, params: &Value) -> Result<Value, (String, String)> {
        match op {
            "identify" => Ok(identify_payload(&self.env, self.pid)),
            "ui.navigate" => self.navigate(params),
            "ui.current_pane" => Ok(json!({ "pane": self.ui_get("pane") })),
            "ui.computed_style" => Ok(json!({ "style": self.ui_get("style") })),
            // Which modal (if any) the frontend has open: "prefs" | "create" | null.
            "ui.modal" => Ok(json!({ "modal": self.ui_get("modal") })),
            "ui.show_window" | "app.activate" => {
                present_main_window(&self.app);
                Ok(json!({}))
            }
            "ui.show_preferences" => {
                present_main_window(&self.app);
                let _ = self.app.emit("show-preferences", json!({}));
                Ok(json!({}))
            }
            "ui.show_create" => {
                present_main_window(&self.app);
                let _ = self.app.emit("show-create", json!({}));
                Ok(json!({}))
            }
            "app.screenshot" => self.screenshot().await,
            "sheds.list" => Ok(json!({ "sheds": self.backend.list_sheds().await })),
            "sheds.refresh" => self.sheds_refresh().await,
            "dashboard.dump" => Ok(json!({ "rows": self.ui_get("sheds").unwrap_or_else(|| json!([])) })),
            "shed.start" => self.shed_action(params, "start").await,
            "shed.stop" => self.shed_action(params, "stop").await,
            "shed.reset" => self.shed_action(params, "reset").await,
            "shed.delete" => self.shed_action(params, "delete").await,
            "create.start" => self.create_start(params).await,
            "create.status" => self.create_status(params),
            "create.cancel" => self.create_cancel(params),
            "system.df" => Ok(json!({ "usage": self.backend.system_df().await })),
            "terminal.preview" => self.terminal_preview(params),
            "terminal.open" => self.terminal_open(params),
            "terminal.presets" => Ok(self.terminal_presets()),
            "prefs.get" => Ok(self.prefs_get()),
            "prefs.set_terminal" => self.prefs_set_terminal(params),
            other => Err(err("unknown_op", format!("unknown op: {other}"))),
        }
    }

    /// `ui.navigate {pane}` → tell the frontend to switch panes (a `navigate`
    /// event). A0a's placeholder frontend ignores it; A0b's React wires it up. It
    /// always acks so the harness can drive navigation.
    fn navigate(&self, params: &Value) -> Result<Value, (String, String)> {
        let pane = params.get("pane").and_then(Value::as_str).unwrap_or("");
        if !matches!(pane, "sheds" | "approvals" | "agents" | "activity" | "system") {
            return Err(err("bad_request", format!("unknown pane: {pane:?}")));
        }
        // The frontend's `navigate` listener attaches asynchronously; the snapshot
        // (hence `pane`) is reported only once it's live, so a navigate before then
        // would be lost. Fail fast so a caller retries (the harness waits first).
        if self.ui_get("pane").is_none() {
            return Err(err("frontend_not_ready", "frontend has not reported yet; retry"));
        }
        let _ = self.app.emit("navigate", json!({ "pane": pane }));
        Ok(json!({}))
    }

    /// `sheds.refresh` → tell the frontend to re-fetch + re-render, then WAIT for
    /// it to echo the refresh token back before returning — so an immediately-
    /// following `dashboard.dump` reflects the new state (mac/gtk's refresh is
    /// synchronous and the harness relies on that). Best-effort at the edges: if
    /// the frontend hasn't mounted yet (cold start) just emit and return — its
    /// mount-fetch populates the dashboard — and never hang if it's slow/gone.
    async fn sheds_refresh(&self) -> Result<Value, (String, String)> {
        let token = self.refresh_seq.fetch_add(1, Ordering::SeqCst) + 1;
        // snapshot present ⟹ the frontend attached BOTH listeners then reported
        // (same readiness invariant as navigate), so the `refresh` emit is heard.
        let has_frontend = self
            .ui
            .lock()
            .ok()
            .is_some_and(|s| s.snapshot.is_some());
        let _ = self.app.emit("refresh", json!({ "token": token }));
        if !has_frontend {
            return Ok(json!({}));
        }
        let deadline = Instant::now() + REFRESH_WAIT;
        loop {
            let echoed = self.ui.lock().ok().map_or(0, |s| s.refresh_token());
            if echoed >= token || Instant::now() >= deadline {
                return Ok(json!({}));
            }
            tokio::time::sleep(REFRESH_POLL).await;
        }
    }

    /// `shed.{start,stop,reset,delete}` → the lifecycle action on `{host?, name}`,
    /// dispatched by the shared [`Backend::shed_action`].
    async fn shed_action(&self, params: &Value, action: &str) -> Result<Value, (String, String)> {
        let name = req_str(params, "name")?;
        let host = params.get("host").and_then(Value::as_str);
        self.backend
            .shed_action(host, name, action)
            .await
            .map(|()| json!({}))
            .map_err(|e| err("action_failed", e.to_string()))
    }

    /// `create.start` → kick off a create on the pure shed-core CreateStore (its
    /// SSE stream runs on Tauri's tokio runtime); returns `{create_id}` to poll
    /// via `create.status`.
    async fn create_start(&self, params: &Value) -> Result<Value, (String, String)> {
        let name = req_str(params, "name")?;
        let host = params.get("host").and_then(Value::as_str);
        let s = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_string);
        let req = CreateShedRequest {
            name: name.to_string(),
            repo: s("repo"),
            local_dir: s("local_dir"),
            image: s("image"),
            backend: s("backend"),
            cpus: params.get("cpus").and_then(Value::as_i64),
            memory_mb: params.get("memory_mb").and_then(Value::as_i64),
            no_provision: params.get("no_provision").and_then(Value::as_bool),
        };
        let id = self
            .backend
            .create_start(&Handle::current(), host, req)
            .map_err(|e| err("action_failed", e.to_string()))?;
        Ok(json!({ "create_id": id }))
    }

    /// `create.status` → the in-flight create's progress snapshot, or
    /// `{state: "unknown"}` once it's cancelled/gone.
    fn create_status(&self, params: &Value) -> Result<Value, (String, String)> {
        let id = req_str(params, "create_id")?;
        match self.backend.create_status(id) {
            Some(progress) => Ok(json!(progress)),
            None => Ok(json!({ "state": "unknown" })),
        }
    }

    /// `create.cancel` → abort a create's stream + drop its state (idempotent).
    fn create_cancel(&self, params: &Value) -> Result<Value, (String, String)> {
        let id = req_str(params, "create_id")?;
        self.backend.create_cancel(id);
        Ok(json!({}))
    }

    // -- terminal + prefs (delegate to the shared TerminalCtl) ------------

    /// `terminal.preview {shed, host?, session?, preset?, template?}` → the ssh
    /// command + resolved preset/invocation, WITHOUT spawning. `shed` (not `name`)
    /// matches the mac contract; gtk has no terminal.
    fn terminal_preview(&self, params: &Value) -> Result<Value, (String, String)> {
        let shed = req_str(params, "shed")?;
        self.terminal.preview(
            params.get("host").and_then(Value::as_str),
            shed,
            params.get("session").and_then(Value::as_str),
            params.get("preset").and_then(Value::as_str),
            params.get("template").and_then(Value::as_str).map(str::to_string),
        )
    }

    /// `terminal.open {shed, host?, session?, preset?, template?}` → spawn the
    /// resolved opener. DISABLED under test mode (spawning a terminal isn't
    /// hermetic — the harness drives terminal.preview instead).
    fn terminal_open(&self, params: &Value) -> Result<Value, (String, String)> {
        if self.env.test_mode {
            return Err(err(
                "not_enabled",
                "terminal.open is disabled in test mode (use terminal.preview)",
            ));
        }
        let shed = req_str(params, "shed")?;
        self.terminal.open(
            params.get("host").and_then(Value::as_str),
            shed,
            params.get("session").and_then(Value::as_str),
            params.get("preset").and_then(Value::as_str),
            params.get("template").and_then(Value::as_str).map(str::to_string),
        )
    }

    /// `terminal.presets` → the offerable presets + install detection.
    fn terminal_presets(&self) -> Value {
        self.terminal.presets()
    }

    /// `prefs.get` → the persisted prefs (terminal preset + template).
    fn prefs_get(&self) -> Value {
        self.terminal.prefs_get()
    }

    /// `prefs.set_terminal {preset, template?}` → persist the terminal preference.
    fn prefs_set_terminal(&self, params: &Value) -> Result<Value, (String, String)> {
        let template = params.get("template").and_then(Value::as_str).map(str::to_string);
        self.terminal.prefs_set_terminal(req_str(params, "preset")?, template)
    }

    /// `app.screenshot` → shell out to a platform tool and return `{png (base64),
    /// width, height}`. The capture is blocking, so run it off the async worker.
    async fn screenshot(&self) -> Result<Value, (String, String)> {
        let res = tokio::task::spawn_blocking(crate::screenshot::capture)
            .await
            .map_err(|e| err("screenshot_failed", format!("capture task panicked: {e}")))?;
        match res {
            Ok((png, width, height)) => Ok(json!({
                "png": base64::engine::general_purpose::STANDARD.encode(&png),
                "width": width,
                "height": height,
            })),
            Err(e) => Err(err("screenshot_failed", e)),
        }
    }
}

/// A bound IPC server. Bind (in the runtime context) before the window paints so
/// an `identify` right after launch succeeds; then `run()` on the runtime.
pub struct IpcServer {
    listener: UnixListener,
    handler: Arc<Handler>,
}

impl IpcServer {
    pub async fn bind(socket_path: &Path, handler: Handler) -> std::io::Result<Self> {
        if let Some(dir) = socket_path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        // Remove a stale socket so a relaunch can bind. Single-instance (the
        // tauri-plugin) runs first, so a *live* instance never reaches here.
        let _ = std::fs::remove_file(socket_path);
        let listener = UnixListener::bind(socket_path)?;
        // Lock the socket to the owner — it exposes app control + screenshots.
        // Best-effort: $XDG_RUNTIME_DIR is already 0700; the /tmp fallback isn't.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600));
            if let Some(dir) = socket_path.parent() {
                let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
            }
        }
        Ok(Self {
            listener,
            handler: Arc::new(handler),
        })
    }

    pub async fn run(self) {
        loop {
            match self.listener.accept().await {
                Ok((stream, _)) => {
                    let handler = self.handler.clone();
                    tokio::spawn(async move { serve_conn(stream, handler).await });
                }
                Err(e) => {
                    eprintln!("shed-desktop-tauri: ipc accept error: {e}");
                    break;
                }
            }
        }
    }
}

async fn serve_conn(mut stream: UnixStream, handler: Arc<Handler>) {
    // Borrowed split (not `into_split`): both halves stay in this task, so we
    // avoid the Arc that owned-halves would allocate per connection.
    let (rd, mut wr) = stream.split();
    let mut reader = BufReader::new(rd);
    loop {
        let line = match read_capped_line(&mut reader, MAX_FRAME_BYTES).await {
            Ok(Some(line)) => line,
            Ok(None) => break, // clean EOF
            Err(_) => {
                let _ = write_line(
                    &mut wr,
                    &json!({"ok": false, "error": {"code": "frame_too_large", "message": "request exceeds 1 MiB"}}),
                )
                .await;
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let resp = handle_line(trimmed, &handler).await;
        if write_line(&mut wr, &resp).await.is_err() {
            break;
        }
    }
}

/// Read one newline-terminated frame, capping its length so an unterminated/huge
/// line can't force unbounded buffering. Generic over the reader so it's unit-
/// testable on an in-memory slice. Returns `None` at a clean EOF.
async fn read_capped_line<R: AsyncReadExt + Unpin>(
    reader: &mut R,
    max: usize,
) -> std::io::Result<Option<String>> {
    let mut buf: Vec<u8> = Vec::new();
    loop {
        match reader.read_u8().await {
            Ok(b'\n') => return Ok(Some(String::from_utf8_lossy(&buf).into_owned())),
            Ok(byte) => {
                if buf.len() >= max {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "frame too large",
                    ));
                }
                buf.push(byte);
            }
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                return Ok((!buf.is_empty()).then(|| String::from_utf8_lossy(&buf).into_owned()));
            }
            Err(e) => return Err(e),
        }
    }
}

async fn write_line(wr: &mut (impl AsyncWriteExt + Unpin), resp: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(resp).unwrap_or_default();
    bytes.push(b'\n');
    wr.write_all(&bytes).await
}

async fn handle_line(line: &str, handler: &Handler) -> Value {
    let req: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => {
            return json!({"ok": false, "error": {"code": "bad_request", "message": e.to_string()}});
        }
    };
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    let op = req.get("op").and_then(Value::as_str).unwrap_or("");
    let params = req.get("params").cloned().unwrap_or_else(|| json!({}));
    match handler.dispatch(op, &params).await {
        Ok(result) => json!({"id": id, "ok": true, "result": result}),
        Err((code, message)) => {
            json!({"id": id, "ok": false, "error": {"code": code, "message": message}})
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn env(mock: Option<&str>) -> Env {
        Env {
            test_mode: true,
            mock_base_url: mock.map(str::to_string),
            config_path: PathBuf::new(),
            socket_path: PathBuf::from("/run/user/0/shed-tauri/shed-tauri.sock"),
        }
    }

    #[test]
    fn identify_reports_tauri_core_and_hermeticity() {
        let v = identify_payload(&env(Some("http://mock")), 4242);
        assert_eq!(v["platform"], "tauri");
        assert_eq!(v["core"], "rust");
        assert_eq!(v["test_mode"], true);
        assert_eq!(v["mock_base_url"], "http://mock");
        assert_eq!(v["pid"], 4242);
        assert!(v["socket_path"]
            .as_str()
            .unwrap()
            .ends_with("shed-tauri.sock"));
    }

    #[test]
    fn identify_null_mock_when_unset() {
        let v = identify_payload(&env(None), 1);
        assert!(v["mock_base_url"].is_null());
    }

    #[tokio::test]
    async fn read_line_returns_trimmed_frame_then_eof() {
        let mut data: &[u8] = b"{\"op\":\"identify\"}\n";
        let line = read_capped_line(&mut data, MAX_FRAME_BYTES)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(line, "{\"op\":\"identify\"}");
        // Next read hits a clean EOF.
        assert!(read_capped_line(&mut data, MAX_FRAME_BYTES)
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn read_line_caps_oversized_frame() {
        let mut data: &[u8] = b"aaaaaaaaaa"; // 10 bytes, no newline
        let e = read_capped_line(&mut data, 4).await.unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn read_line_trailing_unterminated_is_returned_once() {
        // A final line with no newline is returned, then EOF.
        let mut data: &[u8] = b"tail-no-newline";
        assert_eq!(
            read_capped_line(&mut data, MAX_FRAME_BYTES)
                .await
                .unwrap()
                .as_deref(),
            Some("tail-no-newline")
        );
        assert!(read_capped_line(&mut data, MAX_FRAME_BYTES)
            .await
            .unwrap()
            .is_none());
    }
}
