//! shed-gtk — the display-free, testable surface of the GTK client: env/config
//! resolution (`env`), the shed-core-backed data layer (`backend`), and the IPC
//! dispatch (`ipc`). The `shed-desktop` binary (crate `shed-gtk`) (`src/main.rs`) wires gtk4-rs +
//! libadwaita onto this, so `cargo test -p shed-gtk --lib` exercises IPC + config
//! without a display (GTK libs must be installed to compile; no X server needed
//! to run the lib tests).
//!
//! Primary target is Linux; also builds + runs on macOS via Homebrew GTK
//! (`brew install gtk4 libadwaita`) as a dev / UI-comparison loop. `shed-core`
//! is linked directly here (no UniFFI — that's the Swift app's bridge).

pub mod backend;
pub mod env;
pub mod ipc;
