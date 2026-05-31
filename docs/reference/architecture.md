# Architecture

shed-desktop is a SwiftUI menu-bar app with a deliberate core/UI split. All I/O and logic
live in a UI-free core so they are unit-testable without a running app, and so a future
Linux port can reuse the core.

## Targets

| Target | Role |
|--------|------|
| `ShedKit` | Core, no SwiftUI. HTTP/SSE clients, models, config parsing, the IPC server, screenshot, `UiBridge`/`ShedBackend`. |
| `ShedDesktopUI` | SwiftUI views + the `AppState` observable view-model. |
| `ShedDesktopApp` | The `@main` app: `AppModel` (host poller, windows, IPC handler impl). |
| `shedctl` | CLI driver for the IPC socket. |

## Windows

The dashboard and the menu-bar dropdown are AppKit windows hosting SwiftUI views
(`NSHostingController` / `NSPopover`), managed by `AppModel`. This gives the screenshot op
a stable `NSWindow` handle and makes show/hide deterministic for the test harness, rather
than relying on a SwiftUI `WindowGroup`/`MenuBarExtra` whose backing windows are private.

## Connectivity

- The app talks to each configured `shed-server` directly over HTTP. There is no central
  backend; fan-out happens in-app, concurrently, per host.
- Shed lifecycle has no push event stream, so the dashboard **polls** `GET /api/sheds` on
  an interval (with SSE only for create-progress, which the server does stream).
- The HTTP API has no authentication and relies on network-level access control
  (Tailscale/firewall). The app treats a reachable `shed-server` as already trusted by the
  network, and never exposes it further.

## Security model

The app holds no credentials and no secrets — it coordinates processes that do. The
credential approval gate (M3) is fail-closed: a missing or unresponsive app results in
denial, matching the host agent's unanswered-prompt outcome. The app only ever handles
request metadata, never key material.
