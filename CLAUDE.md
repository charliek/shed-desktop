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
  (`IPC/IPCServer.swift`, `IPC/IPCMessages.swift`), `Screenshot.swift`, and the
  `UiBridge`/`ShedBackend` seam.
- `Sources/ShedDesktopUI/` — SwiftUI views + `AppState` (the observable view-model).
- `Sources/ShedDesktopApp/` — `@main`, `AppModel` (host poller + windows + IPC handler),
  `IPCHandlerImpl`.
- `Sources/shedctl/` — CLI driver for the socket.
- `tools/shedtest/` — pytest functional harness + in-process mock shed-server.

The dashboard + menu are AppKit windows hosting SwiftUI (`NSHostingController`/`NSPopover`)
so the screenshot op has a stable `NSWindow` and show/hide is deterministic.

## The change loop

```bash
swift build && swift test          # compile + unit tests
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

## Milestones

M0 read-only dashboard + IPC spine (done) · M1 lifecycle/create/terminal · M2 RC agent
launcher · M3 the cross-repo approval gate (Unix socket to `shed-host-agent`, SSH-only
gate, fail-closed) · M4 notifications/login-item/packaging. The historical design spec is
`docs/spec.md`.
