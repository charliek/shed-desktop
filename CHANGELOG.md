# Changelog

Notable changes to shed-desktop. Older releases (v0.0.1–v0.0.5) predate this file.

## Unreleased

### Added
- **Failure reason in the activity feed** — a failed or denied credential event
  now shows the host-agent's machine code (e.g. `REGISTRY_NOT_ALLOWED`,
  `APPROVAL_DENIED`) and a short reason on a second line, instead of burying the
  detail in the op line. Successful and anonymous rows are unchanged, and events
  from older host-agents (no `code`/`reason`) render exactly as before. Pairs
  with the shed-extensions audit `code`/`reason` enrichment.

## v0.0.6 — 2026-06-07

A full dashboard theme overhaul, redesigned modal sheets, and an app icon.

### Added
- **"Linen" theme** with a slate-blue accent (light + dark), built on
  appearance-aware color tokens (canvas/surface/border, warm text, accent,
  status/intent colors). Cards gain a surface fill + shadow; backend/namespace
  pills get semantic hues (vz = blue, firecracker = amber, ssh-agent = violet);
  shed action buttons are intent-tinted.
- **New shed** and **Launch agent** rebuilt as centered modal cards over a
  dimmed backdrop (shared sheet components), with CPU/Memory steppers and a
  green Launch CTA. New `ui.show_launch` IPC op (+ `shedctl ui show-launch`) so
  the launch modal is agent-drivable like create.
- **App icon** for the Dock/Finder, generated from the menu-bar glyph
  (`packaging/icon/regenerate.sh`).
- A testable `NSColor(hex:)` sRGB decoder in ShedKit (unit-tested).

### Changed
- The **menu-bar dropdown** is now an opaque, arrow-less panel that sizes to its
  content, with a system-accent hover highlight on its actions (replacing the
  translucent `NSPopover`).
- **Dashboard layout**: the header moved into the content pane with a
  full-height sidebar and larger pane titles; the main window keeps its standard
  titlebar.
