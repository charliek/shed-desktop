//! Shared UI state the React frontend reports to Rust (the `ui_report` command),
//! exposed to the harness over IPC (`ui.current_pane` / `ui.computed_style`).
//!
//! This is the "the truth op reads the RENDERED UI state, not a backend re-query"
//! pattern (A1b's `dashboard.dump` builds on it): the frontend is the source of
//! truth for what's on screen, and Rust just relays what it reported.

use std::sync::{Arc, Mutex};

use serde_json::Value;

#[derive(Default)]
pub struct UiState {
    /// The pane the React shell currently shows (its rendered nav state).
    pub current_pane: Option<String>,
    /// A computed-style sample (body bg/color + the resolved accent) so the
    /// harness can confirm the WebView actually applied the linen CSS — the
    /// machine-checkable half of the WebKitGTK render gate.
    pub computed_style: Option<Value>,
}

/// Shared between the `ui_report` Tauri command (writer) and the IPC handler
/// (reader), so both see the same rendered state.
pub type SharedUi = Arc<Mutex<UiState>>;
