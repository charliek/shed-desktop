//! Shared UI state the React frontend reports to Rust (the `ui_report` command),
//! exposed to the harness over IPC (`ui.current_pane` / `ui.computed_style` /
//! `dashboard.dump`).
//!
//! This is the "the truth op reads the RENDERED UI state, not a backend re-query"
//! pattern: the frontend is the source of truth for what's on screen, and Rust
//! relays what it reported. The frontend reports ONE JSON snapshot per render
//! (`{pane, style, sheds, refresh_token}`) rather than a field per op, so a new
//! reader (sheds now; df/images in A1c) is just another key projection — no
//! `ui_report` signature churn.

use std::sync::{Arc, Mutex};

use serde_json::Value;

#[derive(Default)]
pub struct UiState {
    /// The last snapshot the frontend reported (`{pane, style, sheds, refresh_token}`),
    /// or `None` until the React shell has mounted + reported once.
    pub snapshot: Option<Value>,
}

impl UiState {
    /// Project a key out of the reported snapshot (`pane`, `style`, `sheds`, ...).
    pub fn get(&self, key: &str) -> Option<Value> {
        self.snapshot.as_ref().and_then(|s| s.get(key).cloned())
    }

    /// The refresh token the frontend last echoed (0 if it hasn't reported one),
    /// so a synchronous `sheds.refresh` can wait until the frontend re-fetched +
    /// re-reported — mirroring gtk's blocking glib re-render.
    pub fn refresh_token(&self) -> u64 {
        self.get("refresh_token").and_then(|v| v.as_u64()).unwrap_or(0)
    }
}

/// Shared between the `ui_report` Tauri command (writer) and the IPC handler
/// (reader), so both see the same rendered state.
pub type SharedUi = Arc<Mutex<UiState>>;
