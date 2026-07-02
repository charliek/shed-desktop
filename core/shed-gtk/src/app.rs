//! The GTK application surface: a libadwaita dashboard window listing the sheds
//! shed-core fetches, the async bridge that fetches them, and the UiRequest drain
//! that services GTK-touching IPC ops (screenshot) on the main thread.
//!
//! Panic-trap rules (the plan's M2 spec — runtime panics, not compile errors):
//! shed-core futures are spawned on the tokio `Handle` and the `JoinHandle` is
//! `.await`ed *inside* `glib::spawn_future_local` (never poll a reqwest future on
//! the glib executor → "no reactor" panic). GTK objects stay on the glib main
//! thread; data crossing to a tokio worker is `Send` only (`Arc<Backend>` in,
//! `Vec<Shed>`/PNG `Vec<u8>` out — the `glib::Bytes` texture is flattened to
//! `Vec<u8>` on the main thread before it crosses the reply channel).

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita::prelude::*;
use libadwaita::{Application, ApplicationWindow};
use tokio::runtime::Handle;
use tokio::sync::mpsc;

use shed_core::create::CreateState;
use shed_core::models::{Shed, ShedStatus};
use shed_gtk::backend::Backend;
use shed_gtk::ipc::UiRequest;

pub struct App;

impl App {
    pub fn new(
        app: &Application,
        rt: Handle,
        backend: Arc<Backend>,
        ui_rx: Option<mpsc::UnboundedReceiver<UiRequest>>,
    ) -> Self {
        let list = gtk4::ListBox::new();
        list.set_selection_mode(gtk4::SelectionMode::None);
        list.add_css_class("boxed-list");
        list.set_valign(gtk4::Align::Start);
        list.set_margin_top(12);
        list.set_margin_bottom(12);
        list.set_margin_start(12);
        list.set_margin_end(12);

        let scrolled = gtk4::ScrolledWindow::builder()
            .hscrollbar_policy(gtk4::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();

        let header = libadwaita::HeaderBar::new();
        header.set_title_widget(Some(&libadwaita::WindowTitle::new("shed", "")));

        // A live create-progress banner, revealed only while a create runs.
        let banner = libadwaita::Banner::new("");

        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        root.append(&header);
        root.append(&banner);
        root.append(&scrolled);

        let window = ApplicationWindow::builder()
            .application(app)
            .title("shed")
            .default_width(440)
            .default_height(600)
            .content(&root)
            .build();
        window.present();

        // Shared rendered-sheds state (glib-thread only): fetches write it;
        // `dashboard.dump` reads it. Rc<RefCell> is the idiomatic single-thread
        // shared-mutable; the borrow is always cloned out before a reply/await, so
        // no borrow is ever held across an `.await`.
        let sheds_state: Rc<RefCell<Vec<Shed>>> = Rc::new(RefCell::new(Vec::new()));
        // Banner generation: concurrent creates share one banner, so only the
        // latest owns it — an older timer stops once the generation moves on.
        let banner_gen: Rc<RefCell<u64>> = Rc::new(RefCell::new(0));

        // Bootstrap fetch (the one-shot read bridge). `refresh_dashboard` is the
        // shared fetch→store→render path, reused by `sheds.refresh`.
        {
            let rt = rt.clone();
            let backend = backend.clone();
            let state = sheds_state.clone();
            let list_weak = list.downgrade();
            glib::spawn_future_local(async move {
                refresh_dashboard(&rt, &backend, &state, &list_weak).await;
            });
        }

        // Drain UiRequests on the glib main thread (the !Send bridge): each op
        // touches GTK widgets / UI state here, replying over its oneshot. Only the
        // first (real) activation owns the receiver.
        if let Some(mut ui_rx) = ui_rx {
            let window_for_drain = window.clone();
            let state_for_drain = sheds_state.clone();
            let list_weak = list.downgrade();
            let banner_for_drain = banner.clone();
            let banner_gen_for_drain = banner_gen.clone();
            glib::spawn_future_local(async move {
                while let Some(req) = ui_rx.recv().await {
                    match req {
                        UiRequest::Screenshot { scale, reply } => {
                            let _ = reply.send(render_window_png(&window_for_drain, scale));
                        }
                        UiRequest::Dump { reply } => {
                            let rows = state_for_drain.borrow().clone();
                            let _ = reply.send(rows);
                        }
                        UiRequest::Refresh { reply } => {
                            refresh_dashboard(&rt, &backend, &state_for_drain, &list_weak).await;
                            let _ = reply.send(());
                        }
                        UiRequest::CreateStarted { id, name } => {
                            *banner_gen_for_drain.borrow_mut() += 1;
                            let gen = *banner_gen_for_drain.borrow();
                            show_create_progress(
                                &banner_for_drain,
                                &backend,
                                id,
                                name,
                                banner_gen_for_drain.clone(),
                                gen,
                            );
                        }
                    }
                }
            });
        }

        Self
    }
}

/// Fetch sheds via shed-core on the tokio runtime, then store + render on the
/// glib thread. The one-shot read bridge: the reqwest work is spawned on `rt` and
/// its `JoinHandle` awaited here; the `RefCell` borrow is taken only after the
/// await, never across it.
async fn refresh_dashboard(
    rt: &Handle,
    backend: &Arc<Backend>,
    state: &Rc<RefCell<Vec<Shed>>>,
    list_weak: &glib::WeakRef<gtk4::ListBox>,
) {
    let backend = backend.clone();
    let sheds = rt
        .spawn(async move { backend.list_sheds().await })
        .await
        .unwrap_or_default();
    *state.borrow_mut() = sheds.clone();
    if let Some(list) = list_weak.upgrade() {
        render_sheds(&list, &sheds);
    }
}

/// Reveal a live create-progress banner and poll `create_status` on a glib
/// timeout (a sync store read — no reqwest, so no runtime needed) until the
/// create completes/errors, or is cancelled (its entry is gone).
fn show_create_progress(
    banner: &libadwaita::Banner,
    backend: &Arc<Backend>,
    id: String,
    name: String,
    gen_cell: Rc<RefCell<u64>>,
    my_gen: u64,
) {
    banner.set_title(&format!("Creating {name}\u{2026}"));
    banner.set_revealed(true);
    let banner = banner.clone();
    let backend = backend.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(200), move || {
        // A newer create superseded this one → stop; the newer timer owns the banner.
        if *gen_cell.borrow() != my_gen {
            return glib::ControlFlow::Break;
        }
        match backend.create_status(&id) {
            None => {
                banner.set_revealed(false);
                glib::ControlFlow::Break
            }
            Some(p) => match p.state {
                CreateState::Progress => {
                    if let Some(msg) = p.messages.last() {
                        banner.set_title(&format!("Creating {name}: {msg}"));
                    }
                    glib::ControlFlow::Continue
                }
                CreateState::Complete => {
                    banner.set_title(&format!("Created {name}"));
                    let b = banner.clone();
                    let gen_cell = gen_cell.clone();
                    glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
                        if *gen_cell.borrow() == my_gen {
                            b.set_revealed(false);
                        }
                    });
                    glib::ControlFlow::Break
                }
                CreateState::Error => {
                    let e = p.error.as_deref().unwrap_or("unknown error");
                    banner.set_title(&format!("Create failed: {e}"));
                    glib::ControlFlow::Break
                }
            },
        }
    });
}

fn render_sheds(list: &gtk4::ListBox, sheds: &[Shed]) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
    if sheds.is_empty() {
        let row = libadwaita::ActionRow::builder()
            .title("No sheds")
            .subtitle("No configured host returned a shed.")
            .build();
        list.append(&row);
        return;
    }
    for shed in sheds {
        let row = libadwaita::ActionRow::builder()
            .title(&shed.name)
            .subtitle(row_subtitle(shed))
            .build();
        let dot = gtk4::Label::new(None);
        dot.set_markup(&format!(
            "<span foreground=\"{}\">\u{25cf}</span>",
            status_color(shed.status)
        ));
        row.add_prefix(&dot);
        list.append(&row);
    }
}

/// Render the window to a PNG through its own `GskRenderer` (theme/CSS apply
/// exactly as on screen; works even unfocused/occluded). `glib::Bytes` is not
/// `Send`, so flatten to `Vec<u8>` here on the main thread before it crosses the
/// reply channel. Mirrors ../roost's `render_window_png`.
fn render_window_png(
    window: &ApplicationWindow,
    scale: u32,
) -> Result<(Vec<u8>, u32, u32), String> {
    let logical_w = window.width();
    let logical_h = window.height();
    if logical_w <= 0 || logical_h <= 0 {
        return Err("window not realized (zero size)".to_string());
    }
    let scale_f = scale as f32;

    // `renderer()` is `None` until the surface is realized — a graceful error,
    // never a panic on an early/unrealized window.
    let renderer = window
        .native()
        .and_then(|n| n.renderer())
        .ok_or_else(|| "window renderer not ready".to_string())?;

    let paintable = gtk4::WidgetPaintable::new(Some(window));
    let snapshot = gtk4::Snapshot::new();
    snapshot.scale(scale_f, scale_f);
    paintable.snapshot(&snapshot, logical_w as f64, logical_h as f64);
    let node = snapshot
        .to_node()
        .ok_or_else(|| "empty snapshot (nothing to render)".to_string())?;

    let viewport = gtk4::graphene::Rect::new(
        0.0,
        0.0,
        logical_w as f32 * scale_f,
        logical_h as f32 * scale_f,
    );
    let texture = renderer.render_texture(&node, Some(&viewport));
    let png = texture.save_to_png_bytes().to_vec();
    Ok((png, texture.width() as u32, texture.height() as u32))
}

fn row_subtitle(shed: &Shed) -> String {
    let status = status_label(shed.status);
    if shed.host.is_empty() {
        status.to_string()
    } else {
        format!("{} \u{00b7} {}", shed.host, status)
    }
}

fn status_color(s: ShedStatus) -> &'static str {
    match s {
        ShedStatus::Running => "#33d17a",
        ShedStatus::Starting => "#f6d32d",
        ShedStatus::Error => "#e01b24",
        ShedStatus::Stopped | ShedStatus::Unknown => "#9a9996",
    }
}

fn status_label(s: ShedStatus) -> &'static str {
    match s {
        ShedStatus::Running => "running",
        ShedStatus::Stopped => "stopped",
        ShedStatus::Starting => "starting",
        ShedStatus::Error => "error",
        ShedStatus::Unknown => "unknown",
    }
}
