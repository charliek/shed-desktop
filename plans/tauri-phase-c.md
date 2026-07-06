# Tauri Phase C — menu-bar + Agents/RC + approval-spine hardening

*The "can the Tauri client replace the Swift mac app **and** the GTK Linux `.deb`?" evaluation.*

> **Panel-reviewed (2026-07-04, Codex + Kimi + CodeRabbit).** The direction held; the details were
> reshaped. Verified in-tree: **`objc2-local-authentication` v0.3.2 exists** (the mac gate is a ready crate,
> not hand-rolled bindings); **Tauri emits no tray click events on Linux** (`tauri-2.11.5/src/tray/mod.rs`),
> so the tray is a **platform split**, not one portable design.
>
> **B2 re-reviewed (2026-07-05, Codex + Kimi + CodeRabbit).** The seam decision held; the panel caught 8
> in-tree gotchas now folded into §3.2 (the `-t`-PTY JSON-corruption trap in ssh reuse, private `Backend`
> ssh-targets, `rc`-non-default hiding tests from `make test`, the concurrent-IPC store race, the
> `generate_slug` RNG-dep placement, unpinned per-op timeouts, `invalid-param` code parity, and the retag
> being a file-split not a marker-swap). §3.2 is execution-ready.

## Status — pick up here (2026-07-04)

**Branch `tauri-phase-c`** (off merged `feat/rust-core` = `c10d386`). **6 of ~11 milestones LANDED, all
gates green** (shed-app 76 `--features rc` · tauri crate 12 · e2e-tauri 58 · e2e-ci mac 74 · e2e-gtk 10 ·
WebKitGTK render gate green):
- **B2 — ✅ Agents/RC pane (2026-07-06 autonomous run).** The 5-part port: B2.1 `shed-core::rc` (`dc6cbb8`)
  → B2.2 `shed-app::rc` + the `RcRunner` portability seam (`1c800fd`) → B2.3 Tauri IPC (`1367fd7`) → B2.4
  the live React pane (`919c0f7`) → B2.5 harness retag (`ef75dd1`). `test_agents` green at BOTH `--target
  tauri` (58) AND `--target mac` (74); e2e-gtk additive (10, agents skip). The real-SSH path + hands-on
  runbook: `docs/tauri-b2-agents-test-plan.md`. Adversarial passes caught + fixed 2 real bugs (a CRITICAL
  `TokioProcessRunner` timeout-watchdog hang; a stale-session `list` reconcile).
- **B1a** — system tray + native menu + hide-on-close lifecycle + drivable `tray.dump` (both platforms).
- **A1** — host-agent socket peer-UID check (fail closed). **A2** — one OS gate prompt per id (dedup).
  **A3** — clear session grants on disconnect. **B5** — macOS approval notifier (osascript).
- ⚠️ **Lesson:** the first A1 commit used `getpeereid`, which exists on macOS but **not** glibc, so it broke
  the Linux build (fixed: Linux uses `SO_PEERCRED`). **Run `make tauri-build-linux` (the render gate) for
  ANY shared/Linux change — the mac `e2e-tauri` alone won't catch it.**

**NEXT FOCUS → B2, the Agents/RC pane (§3.2)** — the agent panel is high-value for hands-on testing, so it
leads. Then **a real build/packaging + run test on both macOS + Linux** (toward the flip, §4–§5) — this
hands-on run against a live `shed-host-agent` **can also serve as the B7 / A5 real-agent smoke** (mint +
gate a real approval end-to-end), so B7 need not be a separate step. **When B2 lands, draft a TEST PLAN**
(the key features done vs remaining, per platform) so the maintainer knows exactly what to exercise. After
that: **B1b** (mac popover — the Swift-vs-Tauri decision), **B3** (macOS Touch-ID gate, objc2), **B4**
(prefs + autostart), **A4** (D-Bus withdraw).

**B2 design — LOCKED (2026-07-05, maintainer-agreed; full spec in §3.2). The five decisions:**
1. **RC extraction boundary** — pure classify / `normalize_rc_prompt` / argv / DTOs + `RcSession`/`from_dto`
   → **`shed-core::rc`** (no I/O, no feature flag); the stateful process/SSH/session layer → **`shed-app::rc`**
   behind an **`rc = ["tokio/process"]`** feature (so `shed-gtk` compiles none of it). Layout locked in §3.2.
2. **Runner = the portability seam, not just a test seam.** `RcRunner` trait + `TokioProcessRunner` (real)
   + `FakeRunner` (unit) in `shed-app::rc`. **Driver: mobile (iOS/Android — Tauri OR Flutter) CANNOT spawn
   subprocesses**, so the desktop `ssh … shed-ext-rc` shell-out won't run there; the trait is exactly where
   a mobile in-process-ssh/relay runner plugs in. Serves the north-star — ONE Rust base fanning out to
   Swift-FFI + Tauri desktop + Tauri/Flutter mobile + a future headless Rust `shed`/`shed-host-agent`.
   (This is why the real runner lives in `shed-app`, NOT the Tauri crate — contrast polkit/osascript, which
   are per-client platform-native and correctly live client-side.)
3. **Test-mode session store** — `RcStore` (`Mutex<HashMap<String,RcSession>>`, the mac `rcTable` analog) in
   `shed-app::rc`. The hermetic harness uses the mac-style `test_mode` synth-into-store path (fast, no
   fake-plumbing for list/kill consistency); `FakeRunner` covers the real decode/store/error glue in unit
   tests; `rc.inject_test` writes the store directly (test-mode-only).
4. **FFI-readiness guardrails** — `RcService` is frontend-agnostic (NO `Backend` coupling; the ipc layer
   passes resolved running-sheds + ssh-targets into `list()`/`launch()`); the real runner is wired via
   `RcService::new_default()` so FFI consumers never foreign-implement the async trait; keep ONE `rc`
   feature now, split `rc`/`rc-process` only when the mobile runner lands.
5. **No Swift-FFI in Phase C** — the Swift app keeps `RemoteControl.swift`/`ProcessRunner.swift` untouched;
   `shed-core::rc` is net-new Rust. Bridging `shed-app::rc` to Swift is a Phase-4 export milestone.

**Execution model:** B2 is decomposed into 5 green-per-commit sub-milestones (B2.1 `shed-core::rc` →
B2.2 `shed-app::rc` + fake → B2.3 Tauri IPC → B2.4 React pane → B2.5 harness retag; table in §3.2), each
running implement → `/simplify` → adversarial (`/cursor:rescue` or `/codex`) → fold → gates → commit.

**Still open (NOT B2):** **B1b tray** — Tauri webview popover vs a native-Swift mac menu: decide after the
B1b spike (the maintainer's Swift interest is the *menu-bar*, not the gate, which is settled as objc2).

## 0. TL;DR

Phase A (read / lifecycle / create) and Phase B (the credential-approval spine) are **merged** into
`feat/rust-core` (PR #27, PR #28). Phase C closes the last parity gaps **and builds the menu-bar/tray on
both macOS and Linux**, so we can *evaluate* whether the Tauri client can stand in for both shipped
surfaces. Two tracks run in parallel:

- **Track A — Approval-spine hardening.** The Phase B defense-in-depth follow-ups + B7, pulled forward
  because they gate shipping a credential gate to real users.
- **Track B — Phase C surfaces.** The tray/menu-bar (macOS rich popover / Linux native menu), the Agents/RC
  pane, a macOS Touch-ID `AuthGate`, and a macOS approval notifier.

**Two exit bars (§4):** *evaluation-complete* = every mac surface present + drivable + gate-green in Tauri
on both platforms; *flip-ready* = that **plus** the release engineering (updater, notarization, `.deb`
repackaging, polkit-policy install). Only at *flip-ready* do we flip the Swift mac app **and** the Linux
`.deb` to Tauri, merge `feat/rust-core` → `main`, and ship both.

## 1. Context, guardrails, and primer

The Tauri client (Rust backend + one React/Vite/Tailwind frontend) runs on macOS (WKWebView, the
UI-comparison loop) and Linux (WebKitGTK, the intended shipped target), with Sheds / System / Terminal /
Approvals / Activity live on the shared `shed-core` + `shed-app`. **Phase C's job is to make the Tauri
client a credible full replacement for the Swift mac app** — and to *prove* it, so the flip is a decision
backed by the §4 matrix, not a leap.

**Guardrails (standing constraints):**
1. **The Swift UI stays the core macOS app for now.** Phase C does *not* remove it. The flip is a decision
   at the *end* of Phase C (gated on §4); even after a flip the Swift app remains the rollback path for ≥2
   releases (per `plans/phase-4-rust-core-only.md`).
2. **Keep migrating the Swift app's foundation to the Rust core** (`shed-core-ffi` is already the macOS
   default backend); pull logic down so the Swift app is an increasingly thin shell.
3. **Every new surface is written on the Rust base**, not new Swift. The RC logic (§3.2) lands in
   `shed-core`/`shed-app`, not a per-client re-implementation.

**Primer (so this plan is standalone):**
- **F1–F13** are the fail-closed invariants from `plans/tauri-phase-b.md` §2 (the threat model) — the
  load-bearing ones here: F2 respond-is-no-op-when-disconnected, F3 disconnect-drops-pending, F4
  expiry-re-checked-pre-+-post-gate, F5 AuthGate-is-a-rich-enum-never-bool, F9 audit-before-transmit.
  New Track-A work must preserve them.
- **B7 pass bar** (the flip gate): against a live `shed-host-agent` + a configured secure server on a real
  desktop — the client shows *connected*, mints a control token via `token.get`, an SSH sign routes an
  approval that the polkit/Touch-ID gate **approves end-to-end** (the agent releases the credential;
  audit `decided_by` = touchid), a **cancel expires-to-deny** (no credential released), and **killing the
  agent mid-pending drops the queue** (F3). Full runbook: `plans/tauri-phase-b.md`.

## 2. Track A — Approval-spine hardening (production-solidity)

The gate is merged + hermetically green, but four defense-in-depth items + B7 were deferred in the Phase B
reviews. None are violations today; each is a flip gate. `A5 = B7` (one item, two names).

- **A1 — Peer-UID check on the host-agent socket** (`host_agent.rs`). Read the connected server's UID
  (`SO_PEERCRED` on Linux / `getpeereid` on macOS, off the `AsRawFd`) right after `UnixStream::connect` in
  `run_loop` (:264-268, beside `socket_is_trustworthy` :391), and **fail closed on mismatch** — before the
  stream is split or `writer` is set (today `writer` is set immediately at :278; the check must gate it, or
  there's a window where we'd write to a wrong-UID peer). **Scoping (corrected):** this does *not* stop
  *same-UID* socket squatting (a same-user squatter passes `peer_uid == our_uid`); with `$XDG_RUNTIME_DIR`
  `0700` + F11, same-UID squatting is the residual threat A1 can't close. A1's real value is the
  **weak-perms** cases — the `/tmp/shed-tauri-<uid>` fallback, a mis-permissioned XDG dir, and **macOS**
  (the socket resolves to `~/.local/share/shed/host-agent.sock` when `XDG_RUNTIME_DIR` is unset,
  `env.rs:61-76`). Defense-in-depth, not "the biggest win." **Observability:** a persistent wrong-UID peer
  must surface a distinct *"host-agent present but untrusted (UID mismatch)"* state, not a silent
  connect→reject→backoff loop. **Testability:** factor a `read_peer_uid(fd)` seam + a pure
  `peer_trusted(peer, ours) -> bool`; a wrong-UID case is only a unit test *behind that seam* (you can't
  bind a real different-UID peer without privileges).
- **A2 — In-flight-gate dedup** (`coordinator.rs::begin_decide`). Repeated gated *approves* on one pending
  id spawn N concurrent OS prompts. This is a **DoS/robustness** item, **not** a correctness one —
  `finish_decide`'s re-validation already makes a late duplicate a no-op, so there's no double-approve.
  Dedupe the gated **approve** prompt (one OS dialog per id), but a **deny must still remove pending** (and
  make a late approve completion a no-op). Clear the in-flight marker on **every** terminal path —
  `finish_decide`, disconnect, expire-while-in-flight, same-id replacement, and a never-resolving gate — or
  a hung `pkcheck` wedges that id.
- **A3 — Clear session-grants on disconnect** (`coordinator.rs::Disconnected` :439-454; field :332). We
  already clear `pending` + `gate_namespaces`; also clear **all** `session_grants` (not just `ssh-agent` —
  simpler and strictly safer; scoping to a namespace invites a bug if `gate_namespaces` differ across
  reconnect), so a reconnected/squatting agent can't inherit a grant.
- **A4 — D-Bus notification withdraw** (`approval.rs::NotifySendNotifier::withdraw`, a no-op today).
  Capture the `Notify` id and `CloseNotification` it on resolve — via **`zbus`** (DECIDED). Unit-test that
  the id is captured + reused (a full D-Bus round-trip is hard to assert hermetically).
- **A5 (= B7) — real-agent smoke** *(the flip gate)*. Deferred by the maintainer; run per the §1 pass bar
  before the flip.

Each Track-A item: implement → `/simplify` → adversarial review (security-critical) → gates → commit;
F1–F13 hold.

## 3. Track B — Phase C surfaces

### 3.1 B1 — The tray / menu-bar (a **platform split**) — the headline

**Parity target** — the Swift menubar (`AppModel.swift:641-701` + `MenuBarContentView.swift`): an
`NSStatusItem` (box glyph + running-count title-badge) opening a borderless `NSPanel` with a header
(host-agent status dot), pending-approval cards (≤3), a running-sheds list (≤6), and footer actions (Open
dashboard · Preferences · Check for Updates · Quit).

**Build** — the Tauri app has **no tray and quits on last-window-close** today (`tauri = { features = [] }`,
one `main` window). Enable the tray (the `tray-icon` feature + capabilities/window labels), then:

- **macOS — a rich popover** webview anchored at the tray (`tauri-plugin-positioner`), mirroring the Swift
  `MenuPanel` content, fed by the existing `approvals-changed`/`approvals_list` + `list_sheds` data (reuse
  the React components). The tray title carries the running-shed count.
- **Linux — a native right-click context menu** (Open dashboard · Approvals · Preferences · Quit) that
  opens the main window. **Verified:** `tauri-2.11.5` emits **no left-click events and no icon geometry on
  Linux** (`src/tray/mod.rs`: "Linux: Unsupported"), so a tray-anchored popover is impossible there — and
  `shed-gtk` has *no* tray at all, so this is net-new, not GTK parity. The pending count rides on the
  tooltip / a menu label. Best-effort; test *logical* state, not pixels.
- **Window lifecycle (both):** hide-on-close needs **both** `WindowEvent::CloseRequested → hide +
  prevent_close` **and** `RunEvent::ExitRequested → api.prevent_exit()` — else the app still dies on
  last-window-close. On macOS, `ActivationPolicy` Accessory↔Regular as the last window closes/opens.
- **Drivability + the `SharedUi` seam:** a `tray.dump` op. **Watch:** `ui_report` writes ONE global
  `SharedUi` blob that `dashboard.dump` reads (`lib.rs:43-48`); the popover is a *second* webview, so it
  must report on its **own channel / a window-keyed snapshot**, or it clobbers the dashboard's truth.
- **No-SNI Linux host:** GNOME needs an SNI extension; without one there's no icon → no opener. The fallback
  is the `.desktop` launcher + the single-instance `app.activate` handoff (`lib.rs:280-292`) — *relaunch
  raises the running instance*. Document + wire it. Ship the `libayatana-appindicator` runtime dep.

### 3.2 B2 — The Agents / RC pane (a **5-part port**, not a retag) — **DESIGN LOCKED 2026-07-05**

**Parity target** — the Swift launcher (`AgentsView.swift` + `AgentLaunchSheet.swift`; ops
`rc.classify/list/launch/kill/inject_test` in `IPCHandlerImpl.swift:112-131`; runtime in
`AppModel.swift` `rcLaunch`/`rcKill`/`rcList`/`rcInjectTest`/`listReal`/`syntheticURL`; pure logic +
models in `ShedKit/RC/RemoteControl.swift` + `Models.swift:233` (`RcSession`/`compositeID`);
process in `ShedKit/RC/ProcessRunner.swift`): launch a `claude-rc` (REPL, optional prompt) or `shell`
in a shed via SSH `shed-ext-rc create --wait`, list sessions (fan-out SSH probe across running sheds),
classify pane output into states, console (tmux attach), kill. The Tauri `AgentsPane` is a `SEED_AGENTS`
stub. Per guardrail #3 (grounded by the panel + the maintainer's multi-frontend north-star).

**The seam decision (LOCKED — Option 1, the portability seam).** The `RcRunner` trait is **not just a
test seam — it is the portability boundary**. The driving fact: **mobile (iOS/Android — whether Tauri
OR Flutter) cannot spawn subprocesses**, so desktop's `ssh … shed-ext-rc` shell-out will not run there;
a mobile client will execute RC via in-process SSH (`russh`) or a host-agent/API relay. The runner trait
is exactly where that alternate execution plugs in, so ONE `RcService` (store + orchestration + DTO
decode + exit→`RcError`) is owned by the shared base and consumed by every frontend (Swift-FFI, Tauri
desktop, Tauri/Flutter mobile, a future headless Rust `shed`/`shed-host-agent`). This is why the real
runner lives in `shed-app`, **not** the Tauri crate (contrast polkit/osascript, which are per-client
platform-native and correctly live client-side): the RC runner is cross-platform app logic every
frontend wants identically.

**FFI-readiness guardrails (make the shared base actually reusable):**
- `RcService` stays **frontend-agnostic** — NO `Backend` coupling. **Shed→ssh-target *resolution* stays
  in `shed-app` (a public `Backend` method, per guardrail #2 — logic lives down, not in the client);** the
  ipc layer only *wires* it: it calls `Backend::resolve_rc_target`/`rc_targets` and passes the resolved
  `RcTarget`s into `RcService::list()`/`launch()`, so `RcService` is a clean (future) UniFFI unit.
- The real runner is wired **internally** via `RcService::new_default()`, so Swift-FFI/Flutter-FFI
  consumers call `launch(...)`/`list(...)` and **never foreign-implement the async `RcRunner` trait**
  (foreign async-trait impls over UniFFI are the painful path; the trait stays a Rust-internal seam for
  test + mobile).
- Feature stays a single **`rc = ["tokio/process"]`** now (bundles `TokioProcessRunner`). Split into
  `rc` (module: trait + service + store) / `rc-process` (the subprocess runner) **only when the mobile
  runner lands** — no unused feature combo today (unexercised flags bit-rot).

**⚠️ Panel-folded gotchas (2026-07-05, Codex + Kimi + CodeRabbit — all verified in-tree; each would trip
an implementer mid-build):**
1. **SSH argv is NOT terminal.rs reuse (H1 — a JSON-corruption trap).** `terminal.rs::ssh_command`
   (`terminal.rs:26`) is *interactive*: `-t` (PTY), `StrictHostKeyChecking=yes`, `UserKnownHostsFile`,
   remote appended as raw argv (no `--`); **no `BatchMode`/`ConnectTimeout`, no option builder.** RC's
   argv (`RemoteControl.swift:327`) is *non-interactive*: **no `-t`**, `BatchMode=yes` + host-key opts +
   `ConnectTimeout`, remote shell-quoted after `--`. A naive reuse gives `shed-ext-rc create/list` a `-t`
   PTY → stderr merges into stdout + terminal control bytes → **corrupts the JSON DTO decode.** Do:
   extract `ssh_host_key_opts(known_hosts)` from `terminal.rs` (+ expose `shell_quote` as `pub(crate)`),
   share ONLY those; RC builds its own no-`-t` argv.
2. **`Backend` exposes no ssh-target accessor (C2).** `ssh_targets`/`SshTarget`/`ssh_target_for`/
   `resolve`/`known_hosts` are all **private** (`backend.rs:28,37,305`); only `host_names()`+`list_sheds()`
   are public. Add public `Backend::resolve_rc_target(host?, shed) -> RcTarget` +
   `rc_targets(host?, shed?) -> Vec<(Shed, RcTarget)>` (running-shed-filtered, default-server-resolved),
   where `RcTarget { server_name, ssh_host, ssh_port, known_hosts }` — `server_name` (= `Shed.host`) is
   needed for the `--target shed:<shed>@<server>` arg. **`backend.rs` is a B2.2/B2.3 file** (not in §7 yet).
3. **`generate_slug` lives in `shed-app::rc`, NOT `shed-core` (M2).** `randomElement()` needs `rand`/
   `fastrand` — `shed-core` is deliberately dep-light, and a random slug can't be asserted in the B2.1
   argv-shape tests. Mac calls slug-gen from the *stateful* layer (`AppModel.rcLaunch`); mirror that —
   `shed-app::rc::launch` generates the slug and passes it into the pure `create_argv(slug, …)`.
4. **Pin per-op timeouts (H2).** `create=30s` (`shed-ext-rc create --wait` blocks ~20s in the shed),
   `list=15s`, `kill=10s` (`AppModel.swift`). "Timeout watchdog" alone → spurious exit-124 on create.
5. **`std::sync::Mutex` can't be held across `await` + concurrent-IPC race (F4).** Tauri serves IPC
   concurrently (`ipc.rs`), so a `list` wholesale store-rebuild races a concurrent `launch`/`kill`. Collect
   probe results into a local `Vec`, then take the lock for one short critical section; **`list` reconciles
   only the probed `(host,shed)` keys** (don't global-clobber a just-launched session). Serialize the real
   ops behind a per-service `tokio::Mutex` if simpler.
6. **`rc` non-default → `make test` skips the rc tests (F3).** `make test` = `cd core && cargo test`
   (default features); `shed-gtk` links `shed-app` featureless (so `rc` MUST stay non-default). Add
   `cargo test -p shed-app --features rc` to `core-test` (Makefile) or the rc unit tests silently never run.
7. **Error-code parity (F7).** The 3 `test_launch_rejects_*` assert `code == "invalid-param"`; Tauri's
   `err()` vocab is `bad_request`/… — so rc-validation must emit `err("invalid-param", …)` (the helper
   takes any code) to match mac.
8. **The retag is a file SPLIT, not a marker swap (C1).** At `--target tauri`, `test_agents.py` breaks on
   mac-only shapes: `show_launch()` (`ui.show_launch` — absent on tauri, and the tauri pane is an inline
   *form*, not a sheet), `host_list()` (`host.list` — absent), `screenshot(surface=…)` (mac-only kwarg →
   `TypeError` on the surface-less rust-core `screenshot(scale)`), and `refresh()` (mac alias → use
   `sheds_refresh()`). **Split:** behavioral tests (classify/launch/list/kill/prompt-norm/console-preview/
   managed-provenance) → `needs_agents` (swap `refresh`→`sheds_refresh`, derive the inject host from
   `sheds.list` not `host.list`); the screenshot/launch-sheet/legacy-render tail **stays `@mac_only`**; add
   a *tauri-native* pane screenshot test (`navigate("agents")` + `current_pane()` + `screenshot(scale)`).

**Locked module layout (folds the gotchas above):**

- **`core/shed-core/src/rc.rs`** (pure, hermetic, **no feature flag**) — `RcKind` (`claude-rc`/
  `claude-broker`/`shell`; `creatable = {claude-rc, shell}`, broker round-trips only), `RcState`,
  `RcSessionDto`/`RcSessionListDto` (serde, defensive decode), `RcSession` + `composite_id` +
  `from_dto`, `RcError` + `error_from_exit`, `normalize_rc_prompt` (trim → 2000-UTF-8-byte cap →
  control-char reject → kind-accepts-input), `create_argv(slug,…)`/`list_argv`/`kill_argv` (slug is a
  **param**, not generated here), `ssh_argv` (**non-interactive** — no `-t`, BatchMode + `ssh_host_key_opts`
  + ConnectTimeout + `--` + `shell_quote`d remote), `classify_pane`+`extract_url`. Unit tests: every
  classifier case in `test_agents.py`, prompt-norm accept/reject, the exact non-interactive argv shape
  (asserts no `-t`, BatchMode present — the H1 guard), DTO decode, exit→`RcError`. **`ssh_host_key_opts`
  + `shell_quote` are shared out of `terminal.rs` (`pub(crate)`), not duplicated.**
- **`core/shed-app/src/rc.rs`** (feature `rc = ["tokio/process"]`) — `RcStore = Mutex<HashMap<String,
  RcSession>>`; `trait RcRunner { async fn run(&self, argv, stdin: Option<String>, timeout) ->
  io::Result<RunOutput> }`; `TokioProcessRunner` (real: `/usr/bin/env argv`, stdin + timeout watchdog +
  concurrent drain, mirroring `ProcessRunner.swift`); `RcService { store, runner: Arc<dyn RcRunner>,
  clock: ClockRef, test_mode, tool_version }` (`new_default()` wires `TokioProcessRunner`+`SystemClock`).
  **`generate_slug` here.** **test_mode synth (harness):** `launch` synthesizes a ready `RcSession` (url =
  `claude.ai/code/session_<slug>` for claude-rc · `?environment=env_<slug>` for broker · none for shell;
  `created_at` off `clock.now_iso8601()`) into the store; `list` filters; `kill` removes; `inject_test`
  inserts a **full decoded `RcSession`** directly (guarded — errs outside test mode). **Real path:**
  `launch` → `runner.run(ssh(create_argv), stdin, 30s)` → `decode_session` → `from_dto` → store; `list` →
  `futures::join_all` probe (15s) → reconcile probed keys; `kill` → `runner.run(ssh(kill), 10s)` → remove.
  `#[cfg(test)] FakeRunner` covers real decode→store + exit→error; a `FakeClock` pins `created_at`.
  `shed-gtk` (featureless `shed-app`) compiles none of it — **verify gtk still builds**.
- **`core/shed-app/src/backend.rs`** — add the public `resolve_rc_target`/`rc_targets` accessors +
  `RcTarget` (gotcha #2). Resolution logic stays here (shed-app), not the ipc layer.
- **`tauri/src-tauri`** — `ipc.rs` gains `rc.{classify,list,launch,kill,inject_test}` → `RcService` in app
  state (built in `lib.rs::setup`; `test_mode` from the **existing `env.test_mode`** — no new env var);
  the handler calls `Backend::rc_targets`/`resolve_rc_target` and passes `RcTarget`s in; rc-validation
  emits `invalid-param` (#7); `inject_test` behind the `!test_mode → not_enabled` guard (like
  `policy.set`). **Add `agents.dump`** (or `rc_sessions` in `ui_report`) so the pane is drivable by logical
  content, not screenshot-only. Invoke commands + `bridge.ts`: `rcLaunch`/`rcKill` use a **throwing** invoke
  (mirror `createStart` — the default `bridge.ts` helper swallows errors → validation/SSH failures vanish);
  `openTerminal` must **forward `session = rc-<slug>`** (`open_terminal` already accepts it, `lib.rs:184`;
  `bridge.ts` currently drops it). `App.tsx` replaces `SEED_AGENTS` with a live table + launch form (kind
  toggle · display-name · workdir · initial-prompt) + per-row console/open-URL/kill; refetch-on-action.
- **Harness** — a **`_RcOps` mixin** (the rc methods only, `client.py:269-312` — NOT 314-324, which are
  mac-only `window_*`/`screenshot(surface)`; folding those in would clobber `TauriClient`'s screenshot via
  MRO) included by both `ShedDesktop` + `TauriClient`; `needs_agents = {mac, tauri}` in `_marks.py`; the
  file split of #8; the `RcService` test_mode comes from `env.test_mode` (no `SHED_TAURI_*` var); add an
  **RC-store reset** to the conftest reset fixtures (the app is session-scoped; a leaked session would bleed
  — mac self-cleans via `finally` today).

**Sub-milestones (each: implement → `/simplify` (apply) → `/cursor:rescue` or `/codex` adversarial →
fold → gates → commit with trailers; keep every commit green):**

| # | Scope | Gates (must pass) |
|---|---|---|
| B2.1 | `shed-core::rc` pure module + `ssh_host_key_opts`/`shell_quote` extraction in `terminal.rs`. **Coverage bar:** classifier parity with every `test_agents` case, prompt-norm accept/reject, non-interactive argv shape (no `-t` + BatchMode — the H1 guard), DTO decode, exit→`RcError` | `make build && make test` |
| B2.2 | `shed-app::rc` (`rc` feature): store, `RcRunner`+`TokioProcessRunner`, `RcService`(+`generate_slug`, `ClockRef`, pinned timeouts, reconcile-not-clobber), `FakeRunner`/`FakeClock` + tests; **`backend.rs` `RcTarget` accessors**; **gtk builds without `rc`** | `make build && make test` **+ `cargo test -p shed-app --features rc`** + `make tauri-build-linux` + `make tauri-test-linux` + gtk compiles |
| B2.3 | Tauri IPC dispatch (`invalid-param`, `inject_test` guard, `agents.dump`) + invoke + `lib.rs` wiring (via `Backend::rc_targets`). **Add `#[cfg(test)]` `ipc.rs` dispatch tests** (esp. `rc.classify`) so rc.* isn't shipped un-exercised | `make e2e-tauri` + render gate |
| B2.4 | React pane: live table + launch form + console(`session=rc-<slug>`)/open-url/kill; throwing `rcLaunch`/`rcKill` in `bridge.ts` | `make e2e-tauri` + render gate |
| B2.5 | Harness: `_RcOps` mixin (269-312) + `needs_agents` + **split** `test_agents.py` (`refresh`→`sheds_refresh`; mac-only screenshot tail; tauri-native pane screenshot) + conftest RC-store reset | `make e2e-tauri` (`test_agents` at `--target tauri`) + `--target mac` green + `make e2e-gtk` green |

**B2 acceptance:** the behavioral `test_agents.py` subset passes at BOTH `--target mac` AND `--target
tauri`; the mac-only screenshot tail + a tauri-native pane render both green; `cargo test -p shed-app
--features rc` green; render gate + gtk green. **The Swift-FFI adoption of `shed-app::rc` is a real
Phase-4 export milestone, not free — Phase C does NOT bridge `rc` to Swift** (the Swift app keeps its
`RemoteControl.swift`/`ProcessRunner.swift` during the dual-ship window; `shed-core::rc` is net-new Rust).

### 3.3 B3 — The macOS Touch-ID `AuthGate` — **DECIDED: `objc2`**

On macOS `production_seams()` returns `FailClosedGate` → `Unavailable` (`approval.rs:28-38,74-82`), so the
biometrics-or-password method can't complete (button-only "prompt" works). The Swift app has the real thing
(`ShedKit/Approval/TouchID.swift` — `LAContext.evaluatePolicy`). A mac Tauri app can't replace it without it.

**Build** — a `#[cfg(target_os = "macos")]` `TouchIdGate: AuthGate` via **`objc2` +
`objc2-local-authentication` (v0.3.2, verified on crates.io; `objc2 0.6.4` is already transitively in the
tree)** — pure Rust, no Swift compiler in the standalone Tauri workspace. Wrap
`LAContext.evaluatePolicy(policy, localizedReason:)`, mapping `AuthPrompt.biometrics_only` →
`…WithBiometrics` vs `.deviceOwnerAuthentication` (password fallback). Preserve the **rich `AuthOutcome`**
(approved/denied/cancelled/unavailable/error), never a bool.

- **objc2 footguns:** the `LAContext` must be **retained until the reply block fires**; the completion block
  lands on an **arbitrary thread** → bridge it to a `oneshot`; `canEvaluatePolicy == false` → `Unavailable`
  (deny-safe, matching `TouchID.swift:22-24`).
- **Signing coupling:** real Touch ID **won't present from an unsigned/ad-hoc build** — so B3's *real* path
  can't run on dev/CI and is **coupled to the Developer-ID/notarization flip-gate + the A5 smoke**. B3 ships
  with a macOS **unit test** of the deny-safe paths (mirroring `approval.rs::gate_never_approves_without_real_auth`)
  + a documented manual smoke; it isn't "done" until the signed A5 pass.
- The two-phase `begin_decide`/`finish_decide` (`coordinator.rs:504-651`) already mirrors the Swift
  re-check-after-gate, so B3 is *just* the gate impl + a `production_seams()` macOS arm.

### 3.4 B4 — Prefs parity + launch-at-login

Tauri Preferences today expose terminal + approval-method only; the Swift app has richer **SSH policy /
provider** controls — a real parity gap (§4). Add those, plus **launch-at-login** via
`tauri-plugin-autostart` (macOS `SMAppService`), with a `loginitem` state probe for the harness.

### 3.5 B5 — macOS approval notifier — **✅ LANDED (`f743b59`)**

**Done** (commit `f743b59`): a macOS `OsaNotifier` (osascript) replaces the non-Linux `NoopNotifier`, so
the Tauri **mac** app now posts approval banners, mirroring the Swift `SystemNotificationPresenter`. Posts
on a pending prompt, withdraws on resolve; a notification action routes back through `notification.invoke`
(the same path the pane uses). (Historical rationale — the parity gap this closed: `production_seams()`
used to return `NoopNotifier` on non-Linux, so the mac app posted no banners vs the Swift presenter's
approve/deny actions.)

## 4. Exit criteria — two bars, each row mapped to a test

**Bar 1 — evaluation-complete** (surfaces present + drivable + gate-green on both platforms):

| Capability | Swift | Tauri today | Item | Proof |
|---|---|---|---|---|
| Sheds · System · Terminal | ✓ | ✓ (A) | — | existing e2e |
| Approvals · Activity · audit | ✓ | ✓ (B) | — | `test_approvals` |
| Credential gate | Touch ID | polkit ✓ · **mac ✗** | B3 | mac `TouchIdGate` unit test + A5 |
| Gate hardening | n/a | pending | A1–A4 | peer-uid seam / dedup / grant-evict / withdraw tests |
| Agents / RC | ✓ | **stub** | B2 | `test_agents` at `--target tauri` |
| Menu-bar / tray | ✓ | **✗** | B1 | `tray.dump` (mac popover + Linux menu→window) |
| Approval notifications | ✓ | Linux ✓ · **mac ✗** | B5 | notifier posted (or documented delta) |
| Preferences (SSH policy/provider) | ✓ | **partial** | B4 | prefs drive the policy |
| Launch-at-login | ✓ | **✗** | B4 | `loginitem` probe |

**Bar 2 — flip-ready** (adds the release engineering; none are UI):

| Gate | State | Item |
|---|---|---|
| macOS auto-update | Sparkle → **Tauri updater** (signing + manifests) | flip |
| Linux auto-update | **`apt`** (apt-charliek), *not* the Tauri updater | flip |
| macOS Developer-ID sign + notarize the `.app` | **✗** (also unblocks real Touch ID) | flip |
| Linux `.deb` repackage | build-deb.sh/nfpm/release.yml are **GTK-shaped** → WebKit + AppIndicator deps | flip |
| **polkit policy installed** | required — else the Linux gate fails closed for real users | flip |

## 5. Ship plan (post-Phase-C) — the cutover, spelled out

When Bar 1 + Bar 2 are green and the A5 real-desktop pass is clean:
1. **Repackage the Linux `.deb`** GTK → Tauri (WebKit + `libayatana-appindicator` runtime deps; install the
   polkit policy; the GTK client stays buildable but unshipped). Linux keeps updating via `apt`.
2. **Sign + notarize the macOS Tauri `.app`**; stand up the **Tauri updater** (manifests + signing) — the
   mac replacement for Sparkle.
3. **Cutover mechanics (make explicit):** during the dual-ship window, decide whether `git tag vX.Y.Z`
   builds the Swift DMG or the Tauri `.app` (recommend: the Swift app moves to a `legacy`/`mac-swift` tag
   lane for ≥2 releases while Tauri takes the primary tag); how a Sparkle user migrates to the Tauri updater
   (a final Sparkle build that points at the new feed / a one-time migration note); and how rollback is
   actually exercised (keep the Swift DMG buildable + a documented "install the last Swift release" path).
4. **Merge `feat/rust-core` → `main`** and ship both.

Until then: the Swift app + the GTK `.deb` remain shipped; the Tauri client is the candidate.

## 6. Test plan / gates

- Per-commit green: `make build && make test`; `make e2e-tauri` (mac) + `make tauri-build-linux` (WebKitGTK)
  + `make tauri-test-linux` + `make e2e-gtk` (stays green — additive). The tauri CI leg guards it per-PR.
- **Track A** (Rust unit tests): A1 the `peer_trusted` seam (same-UID ok, mismatch fail-closed, lookup-error
  fail-closed); A2 one-OS-prompt-per-id, deny-removes-pending-while-gate-open, marker cleared on all
  terminal paths; A3 disconnect → grants cleared → reconnected request not auto-approved; A4 Notify-id
  captured + reused on withdraw.
- **Track B**: B1 `tray.dump` (own channel, no `SharedUi` clobber) + a no-SNI degradation test (window still
  reachable via `app.activate`) + a mac popover screenshot; B2 the retag's five pieces (esp. the
  `rc.inject_test` fake) + `test_agents` at `--target tauri`; B3 the macOS `TouchIdGate` deny-safe **Rust
  unit test** (test-mode uses `AlwaysApprovedGate`, so the fail-closed assertion is a unit test of the real
  gate, not a harness test) + a manual Touch-ID smoke; B5 notifier-posted assertion.
- **Release validation** (flip): install the repackaged `.deb` in a clean container → assert WebKit +
  AppIndicator deps resolve, the polkit policy is installed, and a real approval smoke passes.
- Security-critical items (A1–A4, B3) get an adversarial review pass, as Phase B's did.

## 7. Sequencing + milestones

Track A ∥ Track B; **flip gate = Track A complete (incl. A5) + Bar 1 + Bar 2 green.** Spikes first.

| # | Item | Files | Acceptance | Platform | Risk |
|---|---|---|---|---|---|
| S1 | **Tray spike** | `lib.rs`, `tauri.conf.json`, capabilities | mac popover positions; Linux menu→window; lifecycle holds | both | **high** (Linux limits) |
| S2 | **objc2 gate spike** | `approval.rs` | `LAContext` compiles + runs; block→oneshot; canEvaluate=false→Unavailable | macOS | med |
| A1 | Peer-UID check ✅ **LANDED** | `host_agent.rs` | seam tests green; untrusted state surfaced | both | med |
| A2 | Gate dedup ✅ **LANDED** | `coordinator.rs` | one-prompt-per-id; deny still evicts; marker cleared all paths | both | low |
| A3 | Clear grants on disconnect ✅ **LANDED** | `coordinator.rs` | eviction test green | both | low |
| B1a | Tray foundation ✅ **LANDED** | `lib.rs`, `tray.rs`, `ipc.rs` | `tray.dump`; hide-on-close | both | — |
| B1 | Tray (mac popover / Linux menu) | `lib.rs`, `App.tsx`, `bridge.ts`, `ipc.rs` | `tray.dump`; own report channel | both | high |
| B3 | macOS Touch-ID gate | `approval.rs`, `Cargo.toml` | deny-safe unit test; manual smoke | macOS | med |
| B2 | Agents/RC ← **NEXT** | `shed-core/rc.rs`, `terminal.rs`, `shed-app/{rc.rs,backend.rs}` (feat `rc`), `ipc.rs`, `lib.rs`, `App.tsx`, `bridge.ts`, harness | `test_agents` at `--target tauri`; `cargo test -p shed-app --features rc` | both | high |
| B5 | macOS notifier ✅ **LANDED** | `approval.rs` | osascript `OsaNotifier` posts/withdraws | macOS | low |
| A4 | D-Bus withdraw | `approval.rs`, `Cargo.toml` | id-captured unit test | Linux | low |
| B4 | Prefs + autostart | `App.tsx`, `bridge.ts`, `lib.rs` | policy drives; `loginitem` probe | both | low |
| A5 | Real-agent smoke (B7) | — | §1 pass bar on a signed build | both | med |
| — | Release: updater / notarize / `.deb` / polkit | `RELEASING.md`, `release.yml`, `build-deb.sh`, `nfpm.yaml`, `packaging/` | Bar 2 green | both | high |

Recommend: **S1 + S2 spikes first** (they de-risk the two highest-risk items and lock the per-platform tray
ACs), then A1–A3 early (small, security-relevant, unblock a clean A5), then B1/B3/B2 in parallel, release
last.

## 8. Decisions

- **Tray** — **DECIDED: platform split.** macOS rich popover; Linux native menu → window (Tauri emits no
  Linux tray click events). Per-platform ACs in §4.
- **D-Bus (A4)** — **DECIDED: `zbus`.**
- **macOS gate (B3)** — **DECIDED: `objc2`** for the Touch-ID call (verified crate; Swift-free build;
  it's one bounded call). The maintainer's Swift-vs-native thought is about the **menu-bar/app integration**
  (B1), not the gate — tracked there.
- **macOS approval notifier (B5)** — **DECIDED: add it** (§3.5) — full mac parity toward a possible
  replacement.
- **RC seam / placement (B2)** — **DECIDED: Option 1, the portability seam** (2026-07-05). `RcRunner` trait
  + real `TokioProcessRunner` + `FakeRunner` in **`shed-app::rc`** (feature `rc`), NOT the Tauri crate.
  Rationale: mobile can't spawn subprocesses, so the trait is the plug-point for a future in-process-ssh /
  relay runner — one shared `RcService` serves Swift-FFI + Tauri + mobile + headless. `RcService` stays
  FFI-ready (no `Backend` coupling; real runner via `new_default()`). Rejected: runner-in-Tauri-crate
  (strands it in one frontend); inline-no-trait (must retrofit the seam when mobile lands). Full spec §3.2.
- **macOS tray implementation (B1) — Tauri now; native-Swift menu is a data-driven option for the flip.**
  Linux must be Tauri regardless. The Tauri webview popover is reversible + evaluate-first; the **S1 spike**
  measures the mac popover's native feel. If it's not good enough for the mac replacement, a native
  `NSStatusItem` + reused `MenuBarContentView` becomes a *targeted* mac upgrade — but that carries a Swift
  toolchain + a bidirectional Rust↔Swift data bridge (the menu needs the coordinator's data) + two tray
  impls to maintain + reverses guardrail #3, so it's justified only if the spike shows the webview popover
  falls short. Decide after S1, with data.
- **Panel review** — **DONE** (this revision folds it).
