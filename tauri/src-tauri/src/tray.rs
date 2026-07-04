//! The system tray / menu-bar (B1a — the foundation).
//!
//! Both platforms get a native menu (Open Dashboard / Quit). On **Linux** that
//! menu IS the tray surface — Tauri emits no tray left-click events or icon
//! geometry there (`tauri-2.11/src/tray/mod.rs`: "Linux: Unsupported"), so a
//! rich anchored popover is impossible; right-click opens the menu. On **macOS**
//! the menu also works (left-click shows it); the rich popover mirroring the
//! Swift `MenuPanel` lands in B1b on top of this. Building the tray is best-effort
//! (a headless / no-SNI host may have nowhere to show it), so a failure logs and
//! the app keeps running — the dashboard window is always reachable.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

/// The tray icon id (so later milestones can fetch + update it — e.g. the count badge).
pub const TRAY_ID: &str = "shed-tray";

/// Menu item ids — kept in sync with [`menu_item_ids`] so `tray.dump` can assert
/// the menu over IPC without reaching into the native menu.
const ID_OPEN: &str = "open";
const ID_QUIT: &str = "quit";

/// The tray menu's actionable item ids, in order — the drivable view of the menu.
pub fn menu_item_ids() -> Vec<&'static str> {
    vec![ID_OPEN, ID_QUIT]
}

/// Build + install the tray. Best-effort: returns the build error to the caller,
/// which logs and continues (the window stays reachable regardless).
pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, ID_OPEN, "Open Dashboard", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, ID_QUIT, "Quit Shed Desktop", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &sep, &quit])?;

    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("Shed Desktop")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            ID_OPEN => show_main(app),
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
