# CLAUDE.md — working in shed-desktop

A native macOS menu-bar app (SwiftUI + AppKit) that coordinates the shed toolchain. This
file orients an AI assistant working in the repo.

## North star

The app is **drivable and observable by an automated agent** — that is a first-class
feature, not a test afterthought. Every change is verified by running the real app and
driving it over the IPC socket (and reading screenshots), not by asking a human to click.
When you add UI or behavior, add the IPC op + harness coverage that lets you verify it.

## Architecture

Core/UI split (see `docs/reference/architecture.md`):

- `Sources/ShedKit/` — core, no SwiftUI. HTTP (`ShedServerClient`) + SSE (`SSEParser`)
  clients, models (`Models.swift`, `ShedConfig.swift`), the IPC server
  (`IPC/IPCServer.swift`, `IPC/IPCMessages.swift`), `Screenshot.swift`, the **Approval**
  subsystem (`Approval/`: `HostAgentClient`, `PolicyEngine`, `AuditStore`,
  `NotificationPresenter`), and the `UiBridge`/`ShedBackend` seam.
- `Sources/ShedDesktopUI/` — SwiftUI views (Sheds/Approvals/Agents/Activity/System/
  Preferences/menu) + `AppState` (the observable view-model).
- `Sources/ShedDesktopApp/` — `@main`, `AppModel` (host poller + windows + IPC handler +
  approval coordinator), `IPCHandlerImpl`, `SystemNotificationPresenter`, the Sparkle
  updater, `PreferencesStore`.
- `Sources/shedctl/` — CLI driver for the socket.
- `tools/shedtest/` — pytest functional harness + in-process mock shed-server.

The dashboard + menu are AppKit windows hosting SwiftUI (`NSHostingController`/`NSPopover`)
so the screenshot op has a stable `NSWindow` and show/hide is deterministic.

## The change loop

```bash
make build && make test            # compile (Rust core + Swift) + unit tests
make bundle                        # build/ShedDesktop.app (ad-hoc signed)
make e2e-ci                        # hermetic functional harness (mock shed-server)
# Eyeball a change against a running app:
make run
build/ShedDesktop.app/Contents/Resources/bin/shedctl ui show-window
build/ShedDesktop.app/Contents/Resources/bin/shedctl screenshot --surface window --out /tmp/s.png
```

The harness is hermetic: it launches the app with `SHED_DESKTOP_TEST_MODE=1` +
`SHED_DESKTOP_MOCK_BASE_URL`, so all HTTP clients hit an in-process mock and no real
shed-server is touched. `identify` is checked up front to confirm hermeticity. Use
condition-waits (`wait_until`), never sleeps.

## Conventions

- Swift 6 strict concurrency. Keep `ShedKit` free of SwiftUI. The IPC handler is an actor;
  reach the app via `@MainActor` op methods that return only `Sendable` results (never
  return the non-`Sendable` `UiBridge` across the actor boundary).
- Default to no comments; add one only when the *why* is non-obvious.
- Decode defensively against real shed-server shapes (`{"sheds": null}`, omitted fields,
  mixed timestamp formats). There are unit tests pinning these.
- Don't expose any shed-server further; a reachable server is trusted by the network, not
  by the app.

## What's built

All shipped (first release `v0.0.1`): the read-only dashboard + IPC drivability spine; shed
lifecycle (start/stop/reset/delete) + create-with-live-SSE-progress + terminal launch; the
remote-control agent launcher; the **credential-approval gate** (a Unix socket to
`shed-host-agent` — multi-server, SSH-gated, fail-closed — with a policy engine,
notifications, and a merged audit feed); the System disk-usage pane; preferences +
launch-at-login; and Sparkle auto-update (DMG + EdDSA appcast — see `RELEASING.md`).

Deferred directions (AWS/Docker gating, sessions/snapshots/images panes, notarization) live
in `docs/roadmap.md`.
