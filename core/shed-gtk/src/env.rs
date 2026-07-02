//! Runtime configuration resolved from `SHED_GTK_*` env vars, mirroring the
//! Swift `ShedBackend` hermeticity hooks so the pytest harness can point the GTK
//! app at an in-process mock + a fixture config without touching real hosts.

use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Env {
    /// `SHED_GTK_TEST_MODE=1` — unlocks test-only behavior + echoed by `identify`.
    pub test_mode: bool,
    /// In test mode, every host client is pointed at this single mock base URL
    /// (`SHED_GTK_MOCK_BASE_URL`). Echoed by `identify` so the harness can fail
    /// fast if a run isn't actually hermetic.
    pub mock_base_url: Option<String>,
    /// The shed config to read (`SHED_GTK_SHED_CONFIG`, else `~/.shed/config.yaml`).
    pub config_path: PathBuf,
    /// The IPC socket path (`SHED_GTK_SOCKET`, else `$XDG_RUNTIME_DIR/shed-gtk/
    /// shed-gtk.sock` with a `/tmp/shed-gtk-<uid>` fallback).
    pub socket_path: PathBuf,
}

impl Env {
    pub fn from_process() -> Self {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let test_mode = std::env::var("SHED_GTK_TEST_MODE").as_deref() == Ok("1");
        // Hermeticity: in test mode, never fall back to the developer's real
        // ~/.shed/config.yaml — an unset config path loads an empty config.
        let config_path = var("SHED_GTK_SHED_CONFIG")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                if test_mode {
                    PathBuf::new()
                } else {
                    default_config_path()
                }
            });
        Self {
            test_mode,
            mock_base_url: var("SHED_GTK_MOCK_BASE_URL"),
            config_path,
            socket_path: var("SHED_GTK_SOCKET")
                .map(PathBuf::from)
                .unwrap_or_else(default_socket_path),
        }
    }
}

fn default_config_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    home.join(".shed/config.yaml")
}

/// `$XDG_RUNTIME_DIR/shed-gtk/shed-gtk.sock`, falling back to
/// `/tmp/shed-gtk-<uid>/shed-gtk.sock` when `XDG_RUNTIME_DIR` is unset (common on
/// macOS) — mirrors roost's `ui.py:80` socket-path resolution.
fn default_socket_path() -> PathBuf {
    let dir = match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(x) if !x.is_empty() => PathBuf::from(x).join("shed-gtk"),
        _ => PathBuf::from(format!("/tmp/shed-gtk-{}", current_uid())),
    };
    dir.join("shed-gtk.sock")
}

fn current_uid() -> u32 {
    // getuid() is infallible and has no safety preconditions.
    unsafe { libc::getuid() }
}
