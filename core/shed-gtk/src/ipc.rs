//! The IPC server: newline-delimited JSON over a Unix socket, the same request
//! envelope shed-desktop's harness speaks — `{id, op, params}` in, `{id, ok,
//! result}` / `{id, ok:false, error:{code,message}}` out. Making the GTK app
//! drivable + observable by an agent over IPC is the North Star.
//!
//! Ops that need only shed-core data (`identify`, `sheds.list`) are serviced
//! here on the tokio runtime. Ops that must touch GTK widgets (`screenshot`) are
//! forwarded to the glib main thread as a [`UiRequest`] carrying a oneshot reply
//! — the `!Send` flattening bridge (roost's `UiRequest`): the GTK thread renders
//! and sends back plain `Send` data (PNG `Vec<u8>`), never a GTK object.

use std::path::Path;
use std::sync::Arc;

use base64::Engine as _;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedReadHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};

use shed_core::models::{CreateShedRequest, Shed};

use crate::backend::Backend;
use crate::env::Env;

/// A request line is tiny; cap it so a local client can't force unbounded
/// buffering with a huge/unterminated frame.
const MAX_FRAME_BYTES: usize = 1 << 20; // 1 MiB
/// Bound `app.screenshot`'s scale so a caller can't request an enormous render.
const MAX_SCREENSHOT_SCALE: u64 = 4;

/// `(png_bytes, width_px, height_px)` or a render error string.
pub type ScreenshotResult = Result<(Vec<u8>, u32, u32), String>;

/// Build an `(code, message)` error pair for the IPC error envelope.
fn err(code: &str, message: impl Into<String>) -> (String, String) {
    (code.to_string(), message.into())
}

/// A request from the IPC handler (tokio thread) to the GTK main thread, for ops
/// that must touch GTK widgets. The glib thread drains these and replies over the
/// embedded oneshot.
pub enum UiRequest {
    Screenshot {
        scale: u32,
        reply: oneshot::Sender<ScreenshotResult>,
    },
    /// Snapshot the dashboard's rendered sheds as data — the deterministic
    /// assertion backbone (unlike the best-effort screenshot). Returns the sheds
    /// the UI currently shows (its rendered state), read on the glib thread.
    Dump { reply: oneshot::Sender<Vec<Shed>> },
    /// Re-fetch sheds via shed-core, update the dashboard's rendered state, and
    /// re-render — so `dashboard.dump` reflects a lifecycle/create change.
    Refresh { reply: oneshot::Sender<()> },
    /// A create just started; the UI shows a live-progress banner (polling
    /// `create_status` on a glib timeout) until it completes/errors.
    CreateStarted { id: String, name: String },
}

/// Services one op at a time; owned by the server and shared across connections.
pub struct Handler {
    env: Env,
    backend: Arc<Backend>,
    ui_tx: mpsc::UnboundedSender<UiRequest>,
    pid: u32,
}

impl Handler {
    pub fn new(env: Env, backend: Arc<Backend>, ui_tx: mpsc::UnboundedSender<UiRequest>) -> Self {
        Self {
            env,
            backend,
            ui_tx,
            pid: std::process::id(),
        }
    }

    /// Dispatch one op. `Ok(result)` → an `ok` envelope; `Err((code, message))`
    /// → an error envelope. `identify`/`sheds.list` are unit-testable without a
    /// socket or a display; `screenshot` needs the GTK thread.
    pub async fn dispatch(&self, op: &str, params: &Value) -> Result<Value, (String, String)> {
        match op {
            "identify" => Ok(self.identify()),
            "sheds.list" => Ok(json!({ "sheds": self.backend.list_sheds().await })),
            "sheds.refresh" => self.sheds_refresh().await,
            "dashboard.dump" => self.dashboard_dump().await,
            "shed.start" => self.shed_action(params, "start").await,
            "shed.stop" => self.shed_action(params, "stop").await,
            "shed.reset" => self.shed_action(params, "reset").await,
            "shed.delete" => self.shed_action(params, "delete").await,
            "create.start" => self.create_start(params).await,
            "create.status" => self.create_status(params),
            "create.cancel" => self.create_cancel(params),
            "app.screenshot" => self.screenshot(params).await,
            other => Err(err("unknown_op", format!("unknown op: {other}"))),
        }
    }

    fn identify(&self) -> Value {
        json!({
            "socket_path": self.env.socket_path.to_string_lossy(),
            "pid": self.pid,
            "core": "rust",
            "platform": "gtk",
            "test_mode": self.env.test_mode,
            "mock_base_url": self.env.mock_base_url,
        })
    }

    /// `dashboard.dump` → the sheds the UI currently shows, as data (`{rows: [...]}`).
    async fn dashboard_dump(&self) -> Result<Value, (String, String)> {
        let (reply, rx) = oneshot::channel();
        self.ui_tx
            .send(UiRequest::Dump { reply })
            .map_err(|_| err("ui_unavailable", "GTK UI not running"))?;
        match rx.await {
            Ok(rows) => Ok(json!({ "rows": rows })),
            Err(_) => Err(err("ui_unavailable", "UI dropped the dump request")),
        }
    }

    /// `shed.{start,stop,reset,delete}` → the lifecycle action on `{host?, name}`.
    async fn shed_action(&self, params: &Value, action: &str) -> Result<Value, (String, String)> {
        let name = params
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| err("bad_request", "missing 'name'"))?;
        let host = params.get("host").and_then(Value::as_str);
        let result = match action {
            "start" => self.backend.start(host, name).await,
            "stop" => self.backend.stop(host, name).await,
            "reset" => self.backend.reset(host, name).await,
            _ => self.backend.delete(host, name).await,
        };
        result
            .map(|()| json!({}))
            .map_err(|e| err("action_failed", e.to_string()))
    }

    /// `sheds.refresh` → re-fetch + re-render the dashboard (so `dashboard.dump`
    /// reflects a lifecycle/create change), on the glib thread.
    async fn sheds_refresh(&self) -> Result<Value, (String, String)> {
        let (reply, rx) = oneshot::channel();
        self.ui_tx
            .send(UiRequest::Refresh { reply })
            .map_err(|_| err("ui_unavailable", "GTK UI not running"))?;
        match rx.await {
            Ok(()) => Ok(json!({})),
            Err(_) => Err(err("ui_unavailable", "UI dropped the refresh request")),
        }
    }

    /// `create.start` → kick off a create on the pure shed-core CreateStore (its
    /// SSE stream runs on the tokio runtime); returns `{create_id}` to poll.
    async fn create_start(&self, params: &Value) -> Result<Value, (String, String)> {
        let name = params
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| err("bad_request", "missing 'name'"))?;
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
        // Best-effort: tell the UI to show a live-progress banner. A dropped send
        // (no UI) is fine — the create still runs and is pollable via create.status.
        let _ = self.ui_tx.send(UiRequest::CreateStarted {
            id: id.clone(),
            name: name.to_string(),
        });
        Ok(json!({ "create_id": id }))
    }

    /// `create.status` → the in-flight create's progress snapshot, or
    /// `{state: "unknown"}` once it's cancelled/gone.
    fn create_status(&self, params: &Value) -> Result<Value, (String, String)> {
        let id = params
            .get("create_id")
            .and_then(Value::as_str)
            .ok_or_else(|| err("bad_request", "missing 'create_id'"))?;
        match self.backend.create_status(id) {
            Some(progress) => Ok(json!(progress)),
            None => Ok(json!({ "state": "unknown" })),
        }
    }

    /// `create.cancel` → abort a create's stream + drop its state (idempotent).
    fn create_cancel(&self, params: &Value) -> Result<Value, (String, String)> {
        let id = params
            .get("create_id")
            .and_then(Value::as_str)
            .ok_or_else(|| err("bad_request", "missing 'create_id'"))?;
        self.backend.create_cancel(id);
        Ok(json!({}))
    }

    /// `app.screenshot` → render the window on the GTK thread and return
    /// `{png (base64), width, height}` (shed-desktop's `app.screenshot` shape).
    async fn screenshot(&self, params: &Value) -> Result<Value, (String, String)> {
        let scale = params
            .get("scale")
            .and_then(Value::as_u64)
            .unwrap_or(1)
            .clamp(1, MAX_SCREENSHOT_SCALE) as u32;
        let (reply, rx) = oneshot::channel();
        self.ui_tx
            .send(UiRequest::Screenshot { scale, reply })
            .map_err(|_| err("ui_unavailable", "GTK UI not running"))?;
        match rx.await {
            Ok(Ok((png, width, height))) => Ok(json!({
                "png": base64::engine::general_purpose::STANDARD.encode(&png),
                "width": width,
                "height": height,
            })),
            Ok(Err(e)) => Err(err("screenshot_failed", e)),
            Err(_) => Err(err("ui_unavailable", "UI dropped the screenshot request")),
        }
    }
}

/// A bound IPC server. Bind synchronously (before the UI exists) so `identify`
/// right after launch succeeds; then `run()` on the tokio runtime.
pub struct IpcServer {
    listener: UnixListener,
    handler: Arc<Handler>,
}

impl IpcServer {
    pub async fn bind(socket_path: &Path, handler: Handler) -> std::io::Result<Self> {
        if let Some(dir) = socket_path.parent() {
            tokio::fs::create_dir_all(dir).await?;
        }
        // Remove a stale socket so a relaunch can bind (single-instance is the
        // harness's job in M2 — it owns the process lifecycle; a flock like
        // roost's lands in M4).
        let _ = tokio::fs::remove_file(socket_path).await;
        let listener = UnixListener::bind(socket_path)?;
        // Lock the socket to the owner — it exposes sheds + screenshots.
        // Best-effort: a chmod failure doesn't stop the listener. $XDG_RUNTIME_DIR
        // is already 0700; the /tmp fallback dir isn't, so tighten it too.
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
                    eprintln!("shed-desktop: ipc accept error: {e}");
                    break;
                }
            }
        }
    }
}

async fn serve_conn(stream: UnixStream, handler: Arc<Handler>) {
    let (rd, mut wr) = stream.into_split();
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
/// line can't force unbounded buffering. `read_u8` pulls from the BufReader's
/// buffer (not a syscall per byte). Returns `None` at a clean EOF.
async fn read_capped_line(
    reader: &mut BufReader<OwnedReadHalf>,
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
    use httpmock::prelude::*;
    use shed_core::config::{ShedConfig, ShedServerEntry};
    use std::path::PathBuf;

    fn env(mock: &str) -> Env {
        Env {
            test_mode: true,
            mock_base_url: Some(mock.to_string()),
            config_path: PathBuf::from("/unused"),
            socket_path: PathBuf::from("/tmp/shed-gtk-test.sock"),
        }
    }

    /// A handler whose UiRequest receiver is dropped — fine for the display-free
    /// ops (identify/sheds.list); a screenshot would report `ui_unavailable`.
    fn handler(env: Env, backend: Arc<Backend>) -> Handler {
        let (ui_tx, _ui_rx) = mpsc::unbounded_channel();
        Handler::new(env, backend, ui_tx)
    }

    fn one_server_config() -> ShedConfig {
        ShedConfig {
            servers: vec![ShedServerEntry {
                name: "mock".into(),
                host: "h".into(),
                http_port: 8080,
                ssh_port: 22,
                control_token: String::new(),
                api_url: String::new(),
                tls_cert_fingerprint: String::new(),
            }],
            default_server: Some("mock".into()),
        }
    }

    #[tokio::test]
    async fn identify_reports_gtk_core_and_hermeticity() {
        let backend = Arc::new(Backend::from_config(
            &ShedConfig::default(),
            Some("http://mock"),
        ));
        let h = handler(env("http://mock"), backend);
        let r = h.dispatch("identify", &json!({})).await.unwrap();
        assert_eq!(r["platform"], "gtk");
        assert_eq!(r["core"], "rust");
        assert_eq!(r["test_mode"], true);
        assert_eq!(r["mock_base_url"], "http://mock");
    }

    #[tokio::test]
    async fn sheds_list_returns_host_stamped_sheds() {
        let server = MockServer::start_async().await;
        server
            .mock_async(|w, t| {
                w.method(GET).path("/api/sheds");
                t.status(200).body(
                    r#"{"sheds":[{"name":"alpha","status":"running"},{"name":"beta","status":"stopped"}]}"#,
                );
            })
            .await;
        let backend = Arc::new(Backend::from_config(
            &one_server_config(),
            Some(&server.base_url()),
        ));
        let h = handler(env(&server.base_url()), backend);
        let r = h.dispatch("sheds.list", &json!({})).await.unwrap();
        let sheds = r["sheds"].as_array().expect("sheds array");
        assert_eq!(sheds.len(), 2);
        assert_eq!(sheds[0]["name"], "alpha");
        assert_eq!(sheds[0]["status"], "running");
        // shed-core stamps the configured server name as the host.
        assert_eq!(sheds[0]["host"], "mock");
        assert_eq!(sheds[1]["status"], "stopped");
    }

    #[tokio::test]
    async fn unknown_op_is_an_error() {
        let backend = Arc::new(Backend::from_config(
            &ShedConfig::default(),
            Some("http://mock"),
        ));
        let h = handler(env("http://mock"), backend);
        let e = h.dispatch("bogus.op", &json!({})).await.unwrap_err();
        assert_eq!(e.0, "unknown_op");
    }

    #[tokio::test]
    async fn test_mode_without_mock_builds_no_clients() {
        // Hermeticity: a partial test env must not dial the developer's real hosts.
        let e = Env {
            test_mode: true,
            mock_base_url: None,
            config_path: PathBuf::from("/does/not/matter"),
            socket_path: PathBuf::from("/tmp/x.sock"),
        };
        assert!(Backend::new(&e).list_sheds().await.is_empty());
    }
}
