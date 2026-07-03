# Tauri Phase A — a real Linux client (foundation)

Status: **panel-reviewed (Kimi K2.6 + CodeRabbit + Cursor, 2026-07-03; Codex rate-limited/skipped) — all
findings folded.** The detailed implementation plan for **Phase A** of [`tauri-desktop.md`](tauri-desktop.md)
(the master plan; read it for the why + the 3-phase shape + the locked decisions). Standalone — a reviewer
needs no prior chat context.

## Context

The GTK client (Phase 2) proved the shared-Rust-core architecture but ships only a read-only dashboard. The
goal is **full Mac↔Linux feature parity (except egress)** with minimal UI duplication. **Tauri** is the bet:
its backend *is* Rust, so `shed-core` is a direct dependency and one web frontend covers Linux desktop
(Android/iOS later). Phase A delivers a **hermetically-tested, drivable Linux client** with the Sheds,
Create (live SSE + cancel), System (df), and Terminal surfaces, running on **Linux (WebKitGTK — shipped)**
and **macOS (WKWebView — the dev/UI-comparison loop vs the SwiftUI app)**.

**Non-goals for Phase A** (deferred): the approval spine (Approvals/Activity, host-agent client,
token-minting, the biometric gate) is **Phase B** (its own security-reviewed plan); Agents/RC, full
preferences, and the tray are **Phase C**. **Phase A's acceptance is mock-only** (the hermetic harness);
it makes **no secure-server-parity claim** — the static config token is not token-minting (that lands in B).
"Shippable" here means *feature-complete for these panes against a reachable server*, gated behind Phase B
for the secure-server credential path.

## Premise — what the `spike/tauri` scaffold already proved (don't re-litigate)

The throwaway spike (branch `spike/tauri`, isolated to `tauri/`) ran **live against a real host** and proved
the integration; a reviewer need not check out that branch — the load-bearing facts are:

1. `shed-core` is a plain path dep; the flow **list → start → create (6 streamed SSE events → complete) →
   delete** worked end to end; Tauri commands are thin `async` shims over a ported `Backend`.
2. **The streaming seam:** `shed-core`'s create is built on the `CreateSink` trait
   (`on_progress`/`on_complete`/`on_error`) that already bridges Swift + GTK. The spike's `TauriCreateSink`
   implements it and calls `app.emit("create-progress", …)` — **one trait bridges Swift, GTK, and Tauri.**
3. **A divergence to reconcile (not a blocker):** the spike's `Backend` *bypasses* `shed_core::create::CreateStore`
   (it uses a bare status map + push events), whereas `shed-gtk`'s `Backend` *uses* `CreateStore` (pull). Phase A
   must reconcile these — see A1b. The spike's `Backend` also reads the dev's real `~/.shed/config.yaml` with
   **no test-mode path**, so it is **not** the extraction base — `shed-gtk/src/backend.rs` (which carries the
   hermetic guard) is.

The harness is already target-parameterized (`--target mac|gtk`); `dashboard_rows(target)` hides the
UI-truth-op difference. A 3rd target needs a client class + launch logic + a `dashboard.dump` op **plus the
per-file `tauri` arms enumerated in A0a** (the existing branches are binary mac/gtk).

## Architecture (Phase A)

### 1. `core/shed-app` — the shared app-logic crate (the keystone, A1a)

A **new** cargo crate in the `core/` workspace, **gtk-free and tauri-free** (no UI deps), depending only on
`shed-core`. It is a **`default-member`** of `core/Cargo.toml` (like `shedctl`) — only `shed-gtk` stays
excluded — so `make core-test` and `core-lint` (`--workspace --exclude shed-gtk`) cover it automatically.

It holds orchestration that is **Swift-only today** (`AppModel.swift`) and absent from `shed-gtk`, so most is
**written new**, guided by the Swift original. **Derive the base `Backend` from `shed-gtk/src/backend.rs`**
(it carries the hermetic guard `test_mode && mock_base_url.is_none() → build zero clients`,
`backend.rs:32–38`), **not** from the spike:

| Piece | Source of truth (Swift) | Milestone / notes |
|---|---|---|
| `Backend` (per-host clients, config load, lifecycle) + `CreateStore` (pull create) | `shed-gtk/backend.rs` (verbatim) | **A1a-move** — the base already exists; keep `CreateStore` + the hermetic guard |
| `refresh()` + **reachability / "N unreachable" rollup** | `AppModel.swift:481–519` (`495–504`, `516–517`) | **A1a-add**, additive: `list_sheds()` keeps its `Vec<Shed>` contract; add a separate `lastError` rollup a client may surface (`0→none`, `1→that error`, `2+→"N hosts unreachable"`). No e2e coverage (mock always 200) → **unit-tested only** |
| An **opt-in `Poller`** (interval + generation-guard + cancellation) | `AppModel.swift:77` (5 s), `433`, `472–519` (guard `476/512`) | **A1a-add**, **opt-in** — a client *starts* it; GTK does not (see the compat contract). Shares the single-writer with `refresh()` (A1b) |
| `system_df()` per-host (→ `[HostDiskUsage]`, unreachable→error row) | `AppModel.swift:524–551` | **A1a-add**; feeds the System pane (A1c) |
| `images()` per-host (→ `[HostImageList]`, unreachable→error row) | `AppModel.swift:556–583` | **A1a-add**; feeds the Create dialog's image picker (A1b), not a pane |
| config **reconnect + reload** (`loadConfigAndClients`) + a **`config.reload` op** for hermetic testing | `AppModel.swift:349–359`, `372–417` | **A1a-add**; the FSEvents/inotify **watcher** (`364–370`, `guard !testMode` → zero hermetic coverage) is **deferred to Phase C** |

- **Platform-seam traits** (impls live in each client): for Phase A only what the above needs — `EventSink`
  (progress/state to the UI: GTK→glib, Tauri→`app.emit`), `Clock` (testable poller time), `Paths` (state/
  config dirs; XDG on Linux), `Opener`/`TerminalSpawn` (A1c). `AuthGate`/`Notifier` are **defined in Phase B**.
- **GTK-compatibility contract (hard requirement).** The refactor is **behavior-preserving for GTK**: GTK does
  **not** start the `Poller`; `list_sheds()` keeps its `Vec<Shed>` contract (no reachability metadata); the
  rollup/df/images/reload APIs are **additive** (GTK ignores them). The `#[cfg(test)]` IPC tests in
  `shed-gtk/src/ipc.rs` that construct `Backend` directly (`ipc.rs:403–406`) either depend on `shed-app` for
  fixtures or move to `shed-app`, leaving `shed-gtk` to test only its GTK-specific IPC glue (the
  `UiRequest` drain, `render_window_png`). **A1a-move is a Tauri-agnostic, independently-revertable first
  commit** so a Tauri stall never strands the shipped GTK client on a half-done refactor.

### 2. `tauri/` — the Tauri app (A0a shell + A0b frontend)

- Layout: top-level **`tauri/`** (mirrors the spike) — `tauri/src-tauri/` (Rust) + `tauri/ui/` (React/Vite).
- `tauri/src-tauri` is a **standalone cargo workspace** (spike-proven: an empty `[workspace]` root so it is
  never absorbed by `core/`) with path deps to `../../core/shed-core` and `../../core/shed-app`. This keeps
  WebKitGTK out of `make build` / `core-lint`. **`tauri/src-tauri/Cargo.lock` is committed** (reproducible
  CI). Trade-off to accept: `shed-app` compiles under **two** lockfiles — `core/`'s (where `cargo test -p
  shed-app` runs) and `tauri/`'s (what the shipped binary links) — so "tested in core/" is not byte-identical
  if a transitive dep (tokio/reqwest/rustls feature unification) resolves differently. Low risk for a pure
  crate; mitigation is `cargo update` discipline + `shed-app` being a `core/` default member so it is at least
  built/tested/linted somewhere on every run.
- **Frontend: React + Vite + Tailwind CSS v3 + shadcn/ui.** **Tailwind is pinned to v3** — v4 emits `oklch()`
  design tokens, uses `color-mix()` for every alpha utility (`bg-black/50`), and `@property` for animated
  vars, which WebKitGTK 2.44 (Ubuntu 24.04's `webkit2gtk-4.1`) may lack and older LTS/22.04 definitely lack;
  v3 defaults to HSL and none of those. shadcn fully supports v3. Vite is Tauri's `beforeBuildCommand`
  (`frontendDist = ../ui/dist`); use `@tauri-apps/api` imports (`invoke`, `event.listen`), **not** the spike's
  `withGlobalTauri`. shadcn components copy into `tauri/ui/src/components/ui/`, re-themed to the linen mockup
  via Tailwind CSS-vars. Strict CSP with nonces (the frontend makes no network calls; all data via `invoke`).

### 3. Drivability — the IPC socket + `--target tauri` (A0a)

- A **newline-JSON IPC socket** in the Tauri Rust process, ported from `core/shed-gtk/src/ipc.rs`: wire
  `{id,op,params}\n → {id,ok,result}` / `{id,ok:false,error:{code,message}}`, 1 MiB frame cap, socket at
  `SHED_TAURI_SOCKET` → `$XDG_RUNTIME_DIR/shed-tauri/shed-tauri.sock` → `/tmp/shed-tauri-<uid>/…` (mirror
  `shed-gtk/src/env.rs:55–64`; perms `0o700` dir / `0o600` sock). UI-thread ops route to the Tauri main
  thread via the `AppHandle` (the GTK analog forwards to the glib thread via an mpsc `UiRequest`).
- **`dashboard.dump` returns the rendered React/app-state snapshot** (what the UI actually shows), **not** a
  fresh `backend.list_sheds()` query — otherwise `dashboard.dump` can read green while the UI is stale. It is
  the primary drivability truth op (matching GTK).
- **Refresh/poll single-writer coherence (A1b requirement).** The `Poller` and on-demand `sheds.refresh`
  write the **same** rendered-state snapshot that `dashboard.dump` reads. They must share **one serialized
  writer** with a generation guard (mirror Swift's `inflightRefresh` chaining `AppModel.swift:462–470` +
  `reloadGeneration`), and `sheds.refresh` must update the dump snapshot **synchronously** before returning —
  else a slow 5 s poll resolves late and clobbers a fresh manual refresh, and `test_lifecycle` /
  `test_dashboard_rows` (which do `sheds.refresh` then assert `dashboard.dump`) go racy.
- **`app.screenshot` returns a real PNG** (the shared `test_screenshot_returns_non_empty_png` requires PNG
  magic + non-zero dims). Tauri has no in-process Linux window capture (WebKitGTK renders web content
  out-of-process), so the backend shells out (`std::process::Command`), trying in order: `grim` (Wayland/
  wlroots only — **fails on GNOME-Wayland**, so dev-best-effort, not the CI path), `scrot` (X11), `import`
  (ImageMagick, X11), `screencapture` (macOS). Under **Xvfb (CI)** it captures the full `$DISPLAY` root window;
  `scale` is a no-op for a root capture. It returns a clear IPC error if no capture backend is available.
  **macOS `screencapture` is TCC-blocked in this harness** (the spike proved it — no Screen-Recording grant),
  so the mac `--target tauri` screenshot test is **best-effort/skipped**; the **Linux/Xvfb capture is the real
  gate**. `dashboard.dump` remains the primary functional primitive; `tauri-driver` is deferred.
- **Harness edits (`tools/shedtest`) — these are required for A0a to pass, not optional:**
  - `client.py`: a `TauriClient(IPCClient)` (adds `dashboard_dump()` + `app.screenshot(scale)`; inherits the
    shared lifecycle/create ops).
  - `test_shared.py::test_identify_is_hermetic`: add a **`tauri` arm** (today the non-gtk `else` asserts
    mac-only `protocol_version==1` + `app_id=="ai.stridelabs.ShedDesktop"`).
  - `ui.py`: `--target tauri` launch/quit (subprocess the Tauri binary with `SHED_TAURI_TEST_MODE=1` /
    `SHED_TAURI_MOCK_BASE_URL=<mock>` / `SHED_TAURI_SHED_CONFIG` + a temp `HOME`/`XDG_RUNTIME_DIR`); add a
    `tauri` arm to `_hermetic` (274–283, currently gtk/mac only) and **generalize `wait_alive`'s crash-detect**
    (`_GTK_PROC`, 266) to any subprocess target.
  - `conftest.py`: add `tauri` to `--target` choices; a `tauri` arm to the `client` fixture (148–154) and to
    `_reset_mock`'s post-reset re-sync (118–120 is gtk-only — a Tauri client with a live poller still needs a
    deterministic `sheds.refresh` re-sync). Reuse the existing `MockShedServer` unchanged.
  - `dashboard_rows("tauri")` → `dashboard.dump.rows`.
- **Single-instance** via a **socket-scoped flock** (ported from `shed-gtk/src/single_instance.rs`, *not*
  the identifier-scoped `tauri-plugin-single-instance`: the plugin's global-per-identifier singleton would
  break hermeticity across parallel / dev instances). A second launch flocks the pidfile beside the socket,
  sends one `app.activate` frame to the running instance, and exits. (The handoff test is Tauri-only — see
  `test_tauri.py`.)

## IPC ops for Phase A (the `--target tauri` contract)

Mirror the GTK op set (`shed-gtk/src/ipc.rs`) plus the two the new panes need:

| Op | Returns | Milestone |
|---|---|---|
| `identify` | `{socket_path,pid,core:"rust",platform:"tauri",test_mode,mock_base_url}` | A0a |
| `ui.navigate` `{pane}` / `ui.show_window` | `{}` | A0a |
| `app.screenshot` `{scale}` | `{png,width,height}` (scale no-op on root capture) | A0a |
| `app.activate` | `{}` (single-instance raise) | A0a |
| `sheds.list` `{host?}` / `sheds.refresh` (synchronous dump update) | `{sheds:[…]}` / `{}` | A1b |
| `dashboard.dump` | `{rows:[Shed]}` (rendered UI truth, not a re-query) | A1b |
| `shed.start/.stop/.reset/.delete` `{host?,name}` | `{}` | A1b |
| `create.start`/`.status`/`.cancel` (cancel via `CreateStore`) | `{create_id}` / `{state,messages,…}` / `{}` | A1b |
| `images.list` `{host?}` | `{hosts:[HostImageList]}` (feeds the picker) | A1b |
| `system.df` | `{hosts:[HostDiskUsage]}` | A1c |
| `terminal.preview` `{host?,name}` | `{argv:[…]}` (built command, **no spawn**) | A1c |
| `terminal.open` `{host?,name}` | `{}` — **disabled under test mode** (spawning isn't hermetic) | A1c |

## Milestones

- **A0a — IPC skeleton + harness (green before any frontend).** The socket + `identify`/`ui.navigate`/
  `ui.show_window`/`app.screenshot`/`app.activate` + single-instance; the `TauriClient` + **all the harness
  arms above**. **Accept:** `--target tauri` `test_identify_is_hermetic` + `test_screenshot_returns_non_empty_png`
  pass (screenshot on Linux/Xvfb; mac best-effort); explicit checks that single-instance handoff works, the
  socket/env resolves, and crash-on-boot is diagnosed (exit-code, not a hang). `ui.navigate`/`app.activate`
  have **no shared test** — assert them via a new `test_tauri.py` check (or mark manual and say so).
- **A0b — React/Vite/Tailwind-v3/shadcn shell + WebKitGTK gate.** The sidebar (Sheds/Approvals/Agents/
  Activity/System + count badges + HOSTS list + "host agent · connected" — later panes are stubs), the linen
  theme (the mockup — imported via the Design MCP project, **committed to `docs/design/shed-desktop-mockup.html`**
  in this milestone as the checked-in parity reference), the Vite `beforeBuildCommand`, strict CSP. **CSS gate — empirical, on the
  real target:** the theme KEEPS the design's authored **oklch** palette (+ inline `color-mix`); WebKitGTK 2.44
  (Ubuntu 24.04) supports oklch, color-mix, `:has()`, `@container`, so a static denylist would be
  *miscalibrated* — the render smoke IS the gate; frontend deps are **pinned**. **Accept:** `make
  tauri-build-linux` (a `webkit2gtk-4.1-dev` + Xvfb Docker job) builds the Rust app and runs the `--target tauri`
  e2e on real WebKitGTK 2.44 — a **computed-style probe** (the frontend reports
  `getComputedStyle(body).backgroundColor`; a failed oklch parse falls back to transparent → the assertion
  fails) + the scrot `app.screenshot` confirm the WebView rendered the theme. **Done: 7 passed on 2.44.**
- **A1a-move — Extract `core/shed-app` (Tauri-agnostic, first, revertable).** Create `shed-app`; move
  `Backend` + `CreateStore` glue **verbatim** from `shed-gtk/src/backend.rs` (keep the hermetic guard);
  refactor `shed-gtk` to depend on it; delete `shed-gtk/src/backend.rs`; relocate/rewire the `ipc.rs:403–406`
  test fixtures. **Touches no Tauri code.** **Accept:** `cargo test -p shed-app` + `cargo test -p shed-gtk
  --lib` + `gtk-lint` + `gtk-build-linux` + `make e2e-gtk` (incl. `test_gtk.py`'s GTK-only no-deadlock +
  second-launch-handoff) all green. Independently revertable.
- **A1a-add — Additive app-logic.** Add the `Poller`, `refresh()` + reachability rollup, `system_df()`,
  `images()`, the config reconnect/reload path + a `config.reload` op, and the `EventSink`/`Clock`/`Paths`/
  `Opener` traits. GTK ignores them (opt-in poller stays off). **Accept:** `cargo test -p shed-app` (see Test
  plan) + `make e2e-gtk` still green.
- **A1b — Sheds + Create.** Per-host grouping; cards (status dot / backend badge / image tag /
  cpu·mem·uptime); status-gated actions. **Create-path reconciliation:** the create stream drives a composite
  sink — `CreateStore` **always** (the pull path: GTK + the harness's `create.status`; `create.cancel` reuses
  `CreateStore`'s idempotent cancel) **plus** an optional `EventSink` tap that `app.emit("create-progress")`
  for Tauri's live UI. The New-Shed dialog's image picker is fed by `images.list`. Tauri **starts the
  `Poller`** here, sharing the single serialized writer with `sheds.refresh`. **Accept:** the shared
  lifecycle/create tests pass at `--target tauri` against the mock (hermetic), with the picker's chosen alias
  asserted to reach the create body (`mock.last_create`).
- **A1c — System + Terminal + terminal pref.** The df cards (`system.df`); `terminal.preview` (returns the
  built argv via the `TerminalSpawn`/`Opener` traits — the platform spawn `x-terminal-emulator`/`$TERMINAL`/
  preset + `openURL`→`xdg-open`); `terminal.open` disabled under test mode; the terminal-preset pref. **Accept:**
  new capability-gated shared (or `--target tauri`) tests for `system.df`, `images.list`, and `terminal.preview`
  pass hermetically (see Test plan). Closes Phase A.

## Files

**Created**
- `core/shed-app/{Cargo.toml,src/lib.rs,src/backend.rs,src/poller.rs,src/refresh.rs,src/traits.rs}` (+
  `#[cfg(test)]`) — the shared crate.
- `tauri/src-tauri/{Cargo.toml,Cargo.lock,tauri.conf.json,build.rs,src/{main,lib,ipc,commands}.rs,capabilities/default.json,icons/…}`
  (reference the spike via `git show spike/tauri:tauri/…`).
- `tauri/ui/{index.html,package.json,vite.config.ts,tailwind.config.*,postcss.config.*,.stylelintrc*,src/**}`.
- `docs/design/shed-desktop-mockup.html` — the committed linen parity reference.
- `tools/shedtest/test_tauri.py` — Tauri-only tests (single-instance handoff; `sheds.list` during create =
  no deadlock; `dashboard.dump` = structured UI truth; `ui.navigate`/`app.activate`).
- CI + packaging: the `tauri-build-linux` Docker job (`webkit2gtk-4.1-dev` **+ `scrot`/`imagemagick`** for
  screenshots, on `ubuntu:24.04`); `make` targets `tauri-run` / `e2e-tauri` / `tauri-build-linux`.
- `docs/reference/…` — a short "Tauri client" note.

**Modified**
- `core/Cargo.toml` — add `shed-app` to `members` **and `default-members`** (only `shed-gtk` stays excluded).
- `core/shed-gtk/src/{backend.rs→deleted,lib.rs,ipc.rs,…}` — depend on `shed-app`; behavior identical.
- `tools/shedtest/{conftest.py,client.py,ui.py,test_shared.py}` — the `tauri` arms enumerated in A0a/§3
  (`--target` choices, `client`/`_reset_mock` fixtures, `TauriClient`, launch/quit, `_hermetic`, `wait_alive`
  crash-detect, the `test_identify_is_hermetic` tauri branch, `dashboard_rows`) + the new capability-gated
  `system.df`/`images.list`/`terminal.preview` shared tests.
- `.github/workflows/ci.yml` — the `tauri-build-linux` leg (its own apt line incl. `scrot`/`imagemagick`).
- `Makefile`, `CLAUDE.md`, `docs/roadmap.md` — the Tauri targets + a client note (roadmap already updated).

## Test plan

- **The cross-target bar** `tools/shedtest/test_shared.py` at `--target tauri` — the 8 shared tests
  (`test_identify_is_hermetic`, `sheds_list_matches_fixture`, `dashboard_rows_match_fixture`,
  `lifecycle_stop_start_delete`, `create_streams_to_complete`, `create_cancel_drops_it`,
  `create_error_surfaced`, `screenshot_returns_non_empty_png`) — all verifiable once the A0a harness arms
  exist. Use `wait_until` (no sleeps). Hermeticity is asserted up front via `identify`.
- **New capability-gated shared tests** for `system.df`, `images.list`, and `terminal.preview` — today these
  are `ShedDesktop`(mac)-only, so the current suite proves nothing about them. Gate them on a target-capability
  set (the same pattern Phase B uses for approvals) so mac + tauri both run them, or write `--target tauri`
  equivalents; either way **commit to writing them** — do not cite non-existent tests as acceptance.
- **`test_tauri.py`** — the genuinely Tauri-only properties (single-instance handoff; no-deadlock during
  create; `dashboard.dump` reflects rendered UI state; `ui.navigate`/`app.activate`).
- **`cargo test -p shed-app`** with fakes (`Clock`/`EventSink`/`Paths`): the reachability rollup (0/1/2+
  hosts — its only coverage, since the mock always returns 200), the `Poller` generation-guard (stale results
  dropped), `system_df()`/`images()` error rows, `loadConfigAndClients` hermeticity (test-mode-without-mock →
  zero clients), hostless ops resolving `default_server`, partial-host-failure keeping healthy sheds, and
  idempotent `create.cancel`.
- **Regression (per A1a-move commit):** `cargo test -p shed-gtk --lib` + `gtk-lint` + `gtk-build-linux` +
  `make e2e-gtk` (incl. `test_gtk.py`) stay green; `make build` + `make test` (core + Swift) + the mac + gtk
  e2e legs stay green throughout (the Tauri crate is exercised by `make tauri-build-linux`, not `make build`).
- **CSS regression:** the stylelint/PostCSS ban + the computed-style IPC probe (A0b) guard against a later
  `npm update` reintroducing WebKitGTK-hostile CSS with nothing red.

## Acceptance criteria (Phase A exit)

1. `tools/shedtest --target tauri` passes the 8 shared tests **plus** the new `system.df`/`images.list`/
   `terminal.preview` capability-gated tests **plus** `test_tauri.py`, all hermetically (mock only).
2. `core/shed-app` exists, is a gtk-free + tauri-free **`default-member`**, has the unit tests above, and
   **both** `shed-gtk` and the Tauri app depend on it; `shed-gtk/src/backend.rs` is gone; `make e2e-gtk`
   (incl. `test_gtk.py`) is green; A1a-move landed as an independently-revertable first commit.
3. The Tauri app builds on **macOS (WKWebView)** and **Linux (WebKitGTK 4.1)**; the linen shell + Sheds/
   Create/System/Terminal render within tolerance of the committed mockup; the computed-style IPC probe and
   the Xvfb screenshot pass in CI.
4. `make build`, `make test`, and the existing mac + gtk e2e legs are all still green (no regression).
5. The new `tauri-build-linux` CI job (build + link + screenshot-tool present) is green.
6. No approval/RC/tray code is introduced (B/C); acceptance is **mock-only** — no secure-server-parity claim.

## Repo conventions to honor

- `shed-core` stays **pure** (no UI, no UniFFI); `shed-app` is UI-free (traits, not widgets). FFI stays in
  `shed-core-ffi` (Swift-only).
- Tauri is **isolated** like `shed-gtk`: `core-lint` stays `--workspace --exclude shed-gtk` and never sees the
  standalone Tauri workspace; `make build` stays GTK/Tauri-free. `shed-app`, being UI-free, is a **default
  member** (the one deliberate difference from `shed-gtk`).
- For the `shed-gtk` refactor, obey the **tokio↔glib panic-trap rules** (`plans/phase-2-rust-clients.md` M2) —
  only `Backend` moves; the glib bridge (`app.rs`'s `spawn_future_local` + `render_window_png`) stays in
  `shed-gtk`. Decode defensively against real server shapes (there are pinned `shed-core` tests).
- Default to **no comments** (only a non-obvious *why*). Match existing file idiom.
- Per-commit loop: `/simplify` → **`/cursor:rescue`** (primary; Codex rate-limited) → `make test` + the
  relevant e2e leg + lint → commit. Every commit green + drivable + hermetic. Commit trailers.
- Branch: `tauri-desktop`, **stacked on `feat/rust-core`** (rebase onto `main` after PR #26 merges); one PR.

## Risks / residual decisions

- **A1a is the biggest milestone** — mitigated by the hard move/add split + the Tauri-agnostic, revertable
  A1a-move + the extended gate (`shed-gtk --lib` + `gtk-lint` + `gtk-build-linux` + `e2e-gtk`).
- **Create-path reconciliation** (`CreateStore` pull + `EventSink` push) is *new integration*, called out in
  A1b so it doesn't surprise the implementer.
- **WebKitGTK CSS** — the real render risk; now machine-gated (Tailwind v3 + stylelint ban + computed-style
  probe) rather than eyeballed. Residual: if a future shadcn component *requires* v4-only CSS, retheme or
  polyfill; don't silently adopt it.
- **Two-lockfile double-build of `shed-app`** — low risk for a pure crate; `cargo update` discipline + the
  default-member test/lint coverage.
- **Config watcher** deferred to C (zero hermetic coverage under the harness); the reload *path* + a
  `config.reload` op land in A1a-add and are hermetically testable.
- **`app.screenshot` on macOS** is TCC-blocked → mac screenshot test best-effort; Linux/Xvfb is the gate.
- **Duplicated IPC wire** — A0a's `tauri/src-tauri/src/{env,ipc,single_instance}.rs` port `shed-gtk`'s
  socket wire (frame codec, `identify`, bind, flock) near-verbatim; the byte-identical pieces are a
  candidate for a shared crate (`shed-app`, or a tiny `shed-ipc`) in a follow-up. A0a keeps it duplicated
  to respect the standalone-workspace isolation — the `read_capped_line` generic is the version to hoist.
