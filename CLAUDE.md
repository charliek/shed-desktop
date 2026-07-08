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
- `core/` — the shared **Rust core** (a cargo workspace): `shed-core` (pure: HTTP/SSE,
  defensive decoders, control-token FSM, TLS pinning, the `config` parser, the `create`
  store, the approval spine), `shed-app` (the UI-free app-logic layer — the Backend, RC, and
  timefmt), `shed-core-ffi` (the UniFFI staticlib the Swift app links — the macOS **default**
  backend; `SHED_DESKTOP_RUST_CORE=0` forces the legacy Swift path), and `shedctl` (a headless
  UDS/IPC client on `shed-core`, no GUI-toolkit dep — shipped in the Linux `.deb`, drives the
  Tauri app's socket). The shipped **Linux client** is the **Tauri** app (`tauri/`, its OWN
  standalone workspace — see below).
- `tools/shedtest/` — ONE pytest functional harness + in-process mock shed-server, driving
  BOTH UIs via `--target mac|tauri` (default `mac`): the mac-only suites gate on the target,
  the shared suite (`test_shared.py`) runs per target, and `test_tauri.py` is the Tauri-only
  suite.

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

### The Linux client (Tauri) + the `.deb`

The shipped **Linux** client is the **Tauri** app (`tauri/`, React/Vite/Tailwind on WebKitGTK,
built on the shared `shed-core` + `shed-app`) — its own standalone cargo workspace, so its
WebKitGTK/Tauri deps never enter `core`'s. The Linux `.deb` (`shed-desktop`) is built from the
Tauri binary via nfpm (`linux/scripts/build-deb.sh`); `shedctl` ships alongside. The dedicated
GTK client (`shed-gtk`) that used to ship the `.deb` has been retired — see
`plans/tauri-linux-release.md`.

```bash
make tauri-run           # build + launch the Tauri client natively (Mac via Homebrew WebKitGTK / Linux)
make e2e-tauri           # hermetic Tauri pytest (tools/shedtest --target tauri; needs a display)
make tauri-build-linux   # the WebKitGTK render gate: --target tauri on ubuntu:24.04 / WebKitGTK 2.44 (Docker)
make tauri-test-linux    # the Tauri crate's Linux-only approval-seam tests (polkit gate; Docker)
make core-linux          # shed-core cargo test/clippy on Linux (Docker)
make deb-validate        # build the Tauri .deb + install-validate in a clean ubuntu:24.04 container
```

The Tauri app speaks the same JSON IPC (`{id,op,params}`) over `$XDG_RUNTIME_DIR/shed-tauri.sock`
(a `/tmp/shed-tauri-<uid>/` fallback); its hermeticity hooks are `SHED_TAURI_TEST_MODE` /
`SHED_TAURI_MOCK_BASE_URL` / `SHED_TAURI_SHED_CONFIG`. **Run `make tauri-build-linux` (the render
gate) for any shared/Linux change** — the mac WKWebView e2e alone can miss Linux-only breaks. On
Linux the tray is a native menu (Tauri emits no Linux tray-click events → no popover; expected).

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

The shed-server protocol layer is a shared **Rust core** (`shed-core` + `shed-app`) — the macOS
**default** backend and the base for the Tauri client. Both the Swift mac app and the Tauri client
are Rust-core-backed.

The **Tauri** cross-platform client (`tauri/`, React/Vite/Tailwind on `shed-core` + `shed-app`) is
the shipped **Linux** client — the `shed-desktop` `.deb` (with a headless `shedctl`) via
`charliek/apt-charliek` (`apt install shed-desktop`; release pipeline
`create-release → mac + linux → apt-charliek dispatch`, see `RELEASING.md`). It has the full
lifecycle + create + IPC drivability (`dashboard.dump`/`current_pane`/`screenshot`, single-instance
handoff via `app.activate`), the credential-approval spine (Linux polkit gate + zbus notifier), the
Agents/RC pane, the tray/native-menu, and launch-at-login. Phases A–C + the design-parity pass are
merged into `feat/rust-core`; the Tauri crate is its OWN cargo workspace (`tauri/src-tauri`), gated
by `make e2e-tauri` (mac) + `make tauri-build-linux` + `make tauri-test-linux` (WebKitGTK — **run
the render gate for any shared/Linux change**) and the CI `tauri-linux` + `tauri-mac` legs.

The dedicated GTK client (`shed-gtk`) that previously shipped the Linux `.deb` has been **retired**
— the Tauri client replaced it (`plans/tauri-linux-release.md`). The Tauri client is also on track
to **eventually replace the Swift mac app** once its macOS UX is refined; for now the Swift app
stays the macOS artifact (DMG + Sparkle). Historical context:
`plans/phase-2-rust-clients.md` / `plans/phase-3-enhancements.md` / `plans/tauri-phase-c.md`; the
"delete-the-Swift-path" cleanups live in `plans/phase-4-rust-core-only.md`.

Deferred directions (AWS/Docker gating, sessions/snapshots/images panes, notarization) live
in `docs/roadmap.md`.
