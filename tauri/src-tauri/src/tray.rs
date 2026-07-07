//! The system tray / menu-bar (B1a foundation + B1 menu).
//!
//! Both platforms get a native menu (Open Dashboard / Approvals / Preferences /
//! Quit). On **Linux** that menu IS the tray surface — Tauri emits no tray
//! left-click events or icon
//! geometry there (`tauri-2.11/src/tray/mod.rs`: "Linux: Unsupported"), so a
//! rich anchored popover is impossible; right-click opens the menu. On **macOS**
//! the menu also works (left-click shows it); the rich popover mirroring the
//! Swift `MenuPanel` lands in B1b on top of this. Building the tray is best-effort
//! (a headless / no-SNI host may have nowhere to show it), so a failure logs and
//! the app keeps running — the dashboard window is always reachable.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager};

/// The tray icon id (so later milestones can fetch + update it — e.g. the count badge).
pub const TRAY_ID: &str = "shed-tray";

/// Menu item ids — kept in sync with [`menu_item_ids`] so `tray.dump` can assert
/// the menu over IPC without reaching into the native menu.
const ID_OPEN: &str = "open";
const ID_APPROVALS: &str = "approvals";
const ID_PREFS: &str = "preferences";
const ID_QUIT: &str = "quit";

/// The tray menu's actionable item ids, in order — the drivable view of the menu.
pub fn menu_item_ids() -> Vec<&'static str> {
    vec![ID_OPEN, ID_APPROVALS, ID_PREFS, ID_QUIT]
}

/// Build + install the tray. Best-effort: returns the build error to the caller,
/// which logs and continues (the window stays reachable regardless).
///
/// The native menu (both platforms — on Linux it IS the tray surface, since Tauri
/// emits no Linux tray click events) opens the dashboard on the relevant pane, or
/// the Preferences modal. The rich macOS popover (B1b) lands on top of this.
pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, ID_OPEN, "Open Dashboard", true, None::<&str>)?;
    let approvals = MenuItem::with_id(app, ID_APPROVALS, "Approvals", true, None::<&str>)?;
    let prefs = MenuItem::with_id(app, ID_PREFS, "Preferences…", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, ID_QUIT, "Quit Shed Desktop", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &approvals, &prefs, &sep, &quit])?;

    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("Shed Desktop")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            ID_OPEN => show_main(app),
            ID_APPROVALS => open_pane(app, "approvals"),
            ID_PREFS => open_prefs(app),
            ID_QUIT => app.exit(0),
            _ => {}
        });
    // The app's configured icon; without it a macOS status item is invisible.
    if let Some(icon) = app.default_window_icon().cloned() {
        builder = builder.icon(icon);
    }
    builder.build(app)?;
    Ok(())
}

/// Show + focus the main dashboard window (recreating nothing — it's hidden, not closed).
pub fn show_main(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.set_focus();
    }
}

/// Raise the dashboard on `pane` — show the window, then emit the same `navigate`
/// event the webview's bridge listens for (the `ui.navigate` path). The window is
/// hidden, not closed, so the listener is live; showing it first makes the emit land.
fn open_pane(app: &AppHandle, pane: &str) {
    show_main(app);
    let _ = app.emit("navigate", serde_json::json!({ "pane": pane }));
}

/// Raise the dashboard + open the Preferences modal (the `ui.show_preferences` path).
fn open_prefs(app: &AppHandle) {
    show_main(app);
    let _ = app.emit("show-preferences", serde_json::json!({}));
}
