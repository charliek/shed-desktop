//! shed-desktop (crate shed-gtk) — GTK4/libadwaita client for the shed toolchain, on the shared
//! shed-core. Primary target is Linux; also builds + runs on macOS via Homebrew
//! GTK (`brew install gtk4 libadwaita`) as a dev / UI-comparison loop.
//!
//! Thin entry point (mirrors ../roost's roost-linux main): build the tokio
//! runtime, bind the JSON IPC server synchronously so `identify` works right
//! after launch, spawn it on the runtime, then hand the runtime `Handle` + the
//! shed-core `Backend` to the gtk4-rs `App`.

mod app;

use std::sync::Arc;

use gtk4::glib::{self, LogWriterOutput};
use libadwaita::prelude::*;
use libadwaita::Application;

use shed_gtk::backend::Backend;
use shed_gtk::env::Env;
use shed_gtk::ipc::{Handler, IpcServer, UiRequest};
use shed_gtk::single_instance::{self, AcquireError};

use crate::app::App;

const APP_ID: &str = "ai.stridelabs.ShedDesktop";

/// Drop the cosmetic `g_settings_schema_source_lookup` GLib warning that fires
/// on macOS Homebrew GTK4 when libadwaita queries a missing GSettings schema at
/// startup — harmless (the system dark-mode preference) but it crowds out real
/// diagnostics. Mirrors ../roost's roost-linux log filter.
fn install_log_filter() {
    glib::log_set_writer_func(|level, fields| {
        for field in fields {
            if field.key() == "MESSAGE" {
                if let Some(msg) = field.value_str() {
                    if msg.contains("g_settings_schema_source_lookup") {
                        return LogWriterOutput::Handled;
                    }
                }
            }
        }
        glib::log_writer_default(level, fields)
    });
}

fn main() -> glib::ExitCode {
    install_log_filter();

    let env = Env::from_process();

    // Single-instance: flock a pidfile before binding the socket. If another
    // instance already holds it, raise its window (an `app.activate` IPC op) and
    // exit — never unlink its live socket. The flock-before-bind ordering is what
    // makes IpcServer::bind's unconditional stale-socket remove safe. (We don't
    // lean on GApplication D-Bus uniqueness — it's absent headless / on Homebrew
    // GTK and would spawn a second, socket-less window there.)
    let lock_path = single_instance::lock_path_for(&env.socket_path);
    let _instance = match single_instance::acquire(&lock_path) {
        Ok(lock) => Some(lock),
        Err(AcquireError::AlreadyHeld(pid)) => {
            eprintln!("shed-desktop: already running (pid {pid}); activating it");
            let _ = single_instance::activate_running_instance(&env.socket_path);
            return glib::ExitCode::SUCCESS;
        }
        Err(AcquireError::Io(e)) => {
            // Can't determine instance state — proceed rather than block the user
            // (the flock is best-effort robustness, not a correctness gate).
            eprintln!("shed-desktop: single-instance check failed ({e}); continuing");
            None
        }
    };

    let backend = Arc::new(Backend::new(&env));

    // A multi-threaded tokio runtime; its Handle is passed to the App so
    // shed-core (reqwest) futures are spawned here, never on the glib executor.
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("build tokio runtime");
    let rt_handle = rt.handle().clone();

    // Channel for GTK-touching IPC ops (screenshot): the handler sends a
    // UiRequest, the glib main thread drains + services it.
    let (ui_tx, ui_rx) = tokio::sync::mpsc::unbounded_channel::<UiRequest>();

    // Bind the IPC server synchronously before any UI surface exists, so a
    // `shedctl`/harness `identify` immediately after launch succeeds.
    let handler = Handler::new(env.clone(), backend.clone(), ui_tx);
    let server = rt_handle
        .block_on(IpcServer::bind(&env.socket_path, handler))
        .unwrap_or_else(|e| {
            panic!(
                "bind shed-desktop IPC server at {}: {e}",
                env.socket_path.display()
            )
        });
    rt_handle.spawn(async move { server.run().await });

    let app = Application::builder().application_id(APP_ID).build();
    let rt_for_activate = rt_handle.clone();
    let backend_for_activate = backend.clone();
    // connect_activate is `Fn` (may fire more than once); the UI receiver is
    // consumed once, so hand it to the first activation only (roost's pattern).
    let ui_rx = std::cell::RefCell::new(Some(ui_rx));
    app.connect_activate(move |app| {
        let _ = App::new(
            app,
            rt_for_activate.clone(),
            backend_for_activate.clone(),
            ui_rx.borrow_mut().take(),
        );
    });

    let exit = app.run_with_args::<&str>(&[]);
    rt.shutdown_background();
    exit
}
