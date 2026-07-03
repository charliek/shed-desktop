//! shed-gtk — the display-free, testable surface of the GTK client: env/config
//! resolution (`env`), the IPC dispatch (`ipc`), and the single-instance guard
//! (`single_instance`). The shed-core-backed `Backend` now lives in the shared
//! `shed-app` crate (A1a). The
//! `shed-desktop` binary (crate `shed-gtk`, `src/main.rs`) wires gtk4-rs +
//! libadwaita onto this, so `cargo test -p shed-gtk --lib` exercises the IPC,
//! config, and flock paths without a display (GTK libs must be installed to
//! compile; no X server needed to run the lib tests).
//!
//! Primary target is Linux; also builds + runs on macOS via Homebrew GTK
//! (`brew install gtk4 libadwaita`) as a dev / UI-comparison loop. `shed-core`
//! is linked directly here (no UniFFI — that's the Swift app's bridge).

pub mod env;
pub mod ipc;
pub mod single_instance;
