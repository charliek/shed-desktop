//! The IPC server: newline-delimited JSON over a Unix socket — the same envelope
//! the shed-desktop harness + `shedctl` speak (`{id, op, params}` in, `{id, ok,
//! result}` / `{id, ok:false, error:{code,message}}` out). Ported from
//! `shed-gtk/src/ipc.rs`. Making the app drivable + observable by an agent over
//! IPC is the North Star.
//!
//! A0a ops (no shed-core backend yet): `identify` / `ui.navigate` /
//! `ui.show_window` / `app.activate` / `app.screenshot`. Window ops go straight
//! through the Tauri `AppHandle` (its methods are thread-safe) and
//! `app.screenshot` shells out ([`crate::screenshot`]), so — unlike GTK — no
//! main-thread marshalling channel is needed. The sheds/create ops arrive in A1b
//! once `shed-app` exists.

use std::path::Path;
use std::sync::Arc;

use base64::Engine as _;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::env::Env;
use crate::state::SharedUi;

/// A request line is tiny; cap it so a local client can't force unbounded
/// buffering with a huge/unterminated frame.
const MAX_FRAME_BYTES: usize = 1 << 20; // 1 MiB

/// Build an `(code, message)` error pair for the IPC error envelope.
fn err(code: &str, message: impl Into<String>) -> (String, String) {
    (code.to_string(), message.into())
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
    pid: u32,
}

impl Handler {
    pub fn new(env: Env, app: AppHandle, ui: SharedUi) -> Self {
        Self {
            env,
            app,
            ui,
            pid: std::process::id(),
        }
    }

    /// Dispatch one op. `Ok(result)` → an `ok` envelope; `Err((code, message))` →
    /// an error envelope.
    pub async fn dispatch(&self, op: &str, params: &Value) -> Result<Value, (String, String)> {
        match op {
            "identify" => Ok(identify_payload(&self.env, self.pid)),
            "ui.navigate" => self.navigate(params),
            "ui.current_pane" => {
                let pane = self.ui.lock().ok().and_then(|s| s.current_pane.clone());
                Ok(json!({ "pane": pane }))
            }
            "ui.computed_style" => {
                let style = self.ui.lock().ok().and_then(|s| s.computed_style.clone());
                Ok(json!({ "style": style }))
            }
            "ui.show_window" | "app.activate" => {
                present_main_window(&self.app);
                Ok(json!({}))
            }
            "app.screenshot" => self.screenshot().await,
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
        // The frontend's `navigate` listener attaches asynchronously; `current_pane`
        // is set only once it's live, so a navigate before then would be lost. Fail
        // fast so a caller retries (the harness waits for readiness first).
        if self.ui.lock().ok().and_then(|s| s.current_pane.clone()).is_none() {
            return Err(err("frontend_not_ready", "frontend has not reported yet; retry"));
        }
        let _ = self.app.emit("navigate", json!({ "pane": pane }));
        Ok(json!({}))
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
