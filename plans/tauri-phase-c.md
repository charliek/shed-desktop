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

**Branch `tauri-phase-c`** (off merged `feat/rust-core` = `c10d386`). **9 of ~11 milestones LANDED, all
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

**MAINTAINER DECISION (2026-07-06):** for the macOS menu-bar, build the **rich Tauri popover** (B1b) —
the maintainer compared the basic tray menu vs. the Swift app and **prefers the fuller mac-app menu**, so
B1b targets parity with the Swift `MenuBarContentView` (host-agent dot · running sheds · ≤3 pending
approval cards · footer: Open dashboard / Preferences / Check for Updates / Quit), NOT the native-Swift
`NSStatusItem` fallback in §8.

**NEXT FOCUS → BATCH 3 (PLANNED 2026-07-06, branch `tauri-phase-c-batch3` off `feat/rust-core`=`37e962b`;
full design + decomposition in §3.7):** **B4 launch-at-login** → **B3** (macOS Touch-ID gate, objc2) → **B1b**
(the rich mac popover, decision above) — warm-up-first, headline last. Then **A5/B7** (the real-agent smoke).
Maintainer decisions this batch: launch **menu-bar-first** (Swift `.accessory` parity, `!test_mode`-guarded),
"Check for Updates…" a **disabled placeholder** in the popover footer. (The B4 SSH-prefs half already landed;
this batch adds the "Launch at login" toggle to match Swift Preferences.)
The A5/B7 smoke rides along with **a real build/packaging + run test on both macOS + Linux** (toward the
flip, §4–§5): a hands-on run against a live `shed-host-agent` mints + gates a real approval end-to-end, so
B7 need not be a separate step. Test plans are drafted — `docs/tauri-b2-agents-test-plan.md` (B2) +
`docs/tauri-batch2-test-plan.md` (B1/A4/B4).

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

## 3.6 Batch 2 — B1 (expanded tray menu) + B4 (SSH-prefs) + A4 (D-Bus withdraw) — ✅ LANDED CI-green

*Landed CI-green (2026-07-06): **B1** the expanded tray menu (`900780e`), **A4** the D-Bus/`zbus` withdraw
(`bf48a83`), and **B4** SSH-approval-prefs persistence + full modal controls (`e19f08f`) — hands-on runbook
`docs/tauri-batch2-test-plan.md`. The mac rich popover (B1-mac → **B1b**) and launch-at-login
(B4-autostart) are carved out as remaining, and the real-hardware check stays a maintainer hands-on. Same
flow as B2: implement → `/simplify` → adversarial (`/cursor:review` external + an internal reviewer,
cross-checked) → fold → gates → commit green.*

**B1 — tray/menu-bar (headline; B1a foundation is in — `tray.rs`, tray built at `lib.rs:524`, hide-on-close
done).** Remaining, decomposed:
- **B1-mac — the rich popover.** A second `WebviewWindow` ("popover") anchored at the tray via
  **`tauri-plugin-positioner`** (TrayCenter), toggled by the macOS **tray-icon left-click**
  (`on_tray_icon_event`; the menu moves to right-click). Content mirrors the Swift `MenuBarContentView`
  (`Sources/ShedDesktopUI/MenuBarContentView.swift`): a host-agent status dot, ≤3 pending-approval cards,
  ≤6 running sheds, footer (Open dashboard · Preferences · Check for Updates · Quit) — reusing the existing
  React Approvals/Sheds data. `ActivationPolicy` Accessory↔Regular as windows open/close.
- **B1-linux — expand the native menu** (Open dashboard · Approvals · Preferences · Quit; today just
  Open/Quit) + the pending/running count on the **tooltip** (Tauri emits no Linux tray click events, so no
  popover — a hard platform limit). The no-SNI fallback (single-instance `app.activate`) already exists.
- **B1-drivability — `tray.dump` on its OWN channel.** The popover is a 2nd webview; it must report its rows
  under a `popover`/window-keyed key so it does NOT clobber the dashboard's `SharedUi` (the `ui_report`
  merge from B2.4 helps). Plus a **mac popover screenshot** for the Swift-vs-Tauri assessment.
- **Decision:** Tauri webview popover NOW (reversible, evaluate-first — per §8); a native-Swift `NSStatusItem`
  menu stays a flip-time option if the screenshot shows the webview falls short. **The maintainer assesses
  the popover's native feel from the screenshot.**

**B4 — prefs parity + launch-at-login.**
- **B4-ssh** — expose the SSH approval **policy** (always-allow / per-shed-allow / time-based-allow /
  always-ask / always-deny) + **TTL** in the React Preferences. The ipc already carries them
  (`ssh_prefs` returns `{method, policy, ttl}`, `set_ssh_approval` accepts them, F13); today the pane shows
  only the method. Parity target: `PreferencesView.swift` "SSH approvals" section.
- **B4-autostart** — launch-at-login via **`tauri-plugin-autostart`** (the `auto-launch` crate — macOS
  LaunchAgent / Linux `.desktop` autostart; **NOT** `SMAppService`, see the B4 correction below + §3.7) + a
  `loginitem` state probe op for the harness (`Toggle("Launch at login")` parity).
- **Out of scope:** the AWS/Docker **provider** sections (`providerSection`) gate deferred AWS/Docker
  credential support (`docs/roadmap.md`); not built here.

**A4 — D-Bus notification withdraw.** Replace the Linux `NotifySendNotifier` (`approval.rs`, `withdraw` is a
documented no-op) with a **`zbus`**-backed notifier: `post` calls the D-Bus `Notify` method and captures the
returned notification id (keyed by approval id); `withdraw` calls `CloseNotification(id)`. `#[cfg(linux)]`,
best-effort (a D-Bus failure just means no banner — approvals still work via the pane). **Unit-test the id is
captured + reused** on withdraw (a full round-trip is hard to assert hermetically), mirroring the plan's A4.

**⚠️ Panel fold (2026-07-06, Codex + Kimi + CodeRabbit — triple-converged; each reviewer read the tree +
the vendored `tauri-2.11.5` source). B1 is materially bigger than the one-clause sketch above:**

- **B1-mac ui_report clobber (CRITICAL — all 3).** The "B2.4 merge helps" claim above is WRONG: a 2nd
  `WebviewWindow` loads the same `index.html` → same `App`/`useUiBridge` → writes the SAME keys
  (`pane`/`sheds`/`refresh_token`), so it corrupts `dashboard.dump`/`current_pane`/the refresh gate. **Fix:
  window-keyed `ui_report`** — add the `Window` label param, store `snapshot[label]`, `tray.dump` reads the
  `popover` key — OR a **separate popover Vite entry** that doesn't mount `useUiBridge`. Pick one in the spike.
- **B1-mac drivability (HIGH — CodeRabbit/Codex).** OS tray clicks aren't drivable hermetically → the popover
  never mounts in CI → `tray.dump`'s popover key stays empty. Add a **`tray.show`/`tray.toggle` IPC op** that
  runs the exact same Rust path as the mac tray-icon click (the analogue of `ui.show_preferences`).
- **B1-mac tray builder (HIGH — all 3, vendored-source-verified).** `show_menu_on_left_click(false)` is
  MANDATORY (defaults true; else left-click opens both menu + popover). The `Click` event carries
  `button_state: Up|Down` → toggle on ONE edge or it fires twice/click. Platform-split: mac detaches the menu
  (right-click → `show_menu`), Linux keeps it attached. **The spike must prove `on_tray_icon_event` even
  fires with a menu attached.**
- **B1-mac ActivationPolicy (MED — all 3).** Role-aware: `Regular` when the dashboard opens, `Accessory`
  when the last normal window hides (today `lib.rs:531` hides uniformly). **Guard every flip on `test_mode`**
  (the Swift app does — an unguarded flip destabilizes e2e), and BEWARE the launch-visibility↔mount tension:
  a hidden menu-bar-parity window may never mount → `ui_report` never fires → `wait_until(current_pane, 30s)`
  times out. So keep `main` shown at launch in test mode.
- **B1-mac plumbing (MED — Codex/CodeRabbit).** Add `tauri-plugin-positioner` (needs the `tray-icon` feature
  + forwarding `on_tray_icon_event` into `positioner::on_tray_event`); a `popover` window in
  `tauri.conf.json` (borderless/transparent/skipTaskbar); its own **capability** (default.json is scoped to
  `main`); a **new `TrayPopover.tsx` React root** (not the full `App`); dismiss-on-blur (`Focused(false)→hide`).
- **B1-mac screenshot is MANUAL, not a gate (all 3).** `screencapture` is full-display + TCC-gated on mac
  → the content AC is **`tray.dump`** (logical rows); the screenshot is a maintainer visual-assessment
  artifact. Reframe §6 accordingly.
- **B1-linux (Codex correction).** Tauri 2.11 marks the **tray tooltip UNSUPPORTED on Linux** — put the
  pending count on a **disabled/status menu item or a mutable menu label**, not the tooltip. A set Linux menu
  can't be replaced, only mutated → keep mutable `MenuItem` handles. Footer "Check for Updates" → disabled/
  no-op (no Tauri updater in this batch).

- **B4 corrections (Codex/CodeRabbit).** `tauri-plugin-autostart` is **NOT `SMAppService`** — it's the
  `auto-launch` crate (macOS LaunchAgent / AppleScript). Fix the wording + probe `app.autolaunch().is_enabled()`.
  **Test-mode-guard the enable toggle** (mac triggers a real TCC prompt / login-item write — not
  HOME-scoped). **Persist `ssh_method/policy/ttl` + hydrate the coordinator at startup** (today it starts
  `SshPrefs::default()`, `lib.rs:490` — the prefs don't survive a restart). Mirror the Swift **conditional
  visibility** (TTL only for time-based; method only for prompting policies; the SSH section only when ssh is
  gated). The `loginitem` op = `loginitem.status → {enabled}` (+ a guarded `set`); add the client method + test.
- **A4 corrections (all 3).** Add a **`NotifyBus` trait seam** (real zbus impl + a fake returning a canned
  id) so the id-capture test is hermetic (the A1/B2 seam pattern). Handle the **sync-`post`/async-`Notify` +
  early-`withdraw` race** with a state machine (Pending / Posted(id) / WithdrawnBeforeId → close-on-arrival);
  reuse ONE `zbus::Connection` with `features=["tokio"]`; D-Bus-absent (CI container) → timeout + no-op (no
  stuck state). The real motivation: the current banner is `--urgency=critical`, which does NOT auto-expire,
  so a resolved approval lingers. Test cases: capture→close, withdraw-before-id→close-after, dbus-fail→no-stuck,
  dup-post→no-leak.

**Revised sequencing (post-fold).** B1 is now clearly a **large, harness-tension-laden surface that needs the
maintainer's visual call** — NOT a clean autonomous "done." So: land the **clean autonomous wins first — A4,
B4, and B1-linux (the menu expansion + count-on-a-menu-item)** — each fully gated + testable tonight; then a
**budgeted B1-mac popover spike** (resolve the 4 spike-critical questions above, build to a `tray.dump`-drivable
+ screenshot-able state) → **screenshot + checkpoint with the maintainer** for the native-feel / Swift-vs-Tauri
call, rather than autonomously polishing it. Hard budget: if the popover isn't screenshot-able in a few hours,
pivot to the native-Swift `NSStatusItem` option (§8) with data.

## 3.7 Batch 3 — B4 launch-at-login + B3 macOS Touch-ID + B1b mac rich popover — PLANNED (2026-07-06)

*The next batch on a fresh branch `tauri-phase-c-batch3` (off merged `feat/rust-core` = `37e962b`, PR #29).
Turns the decided/deferred items into implementation. **One PR** onto `feat/rust-core`, **one green-per-commit
sub-milestone** each, same flow as B2/Batch-2: implement → `/simplify` (apply) → adversarial (external
`/cursor:review` + an internal general-purpose reviewer, cross-checked per [[review-process]]; a
`ScheduleWakeup`//loop poll when a background review runs) → fold → full gates → commit green.*

**Maintainer decisions (2026-07-06, this batch):**
- **Launch = menu-bar-first (Swift parity).** In production the mac app launches `.accessory` (no Dock icon,
  no window — just the menu-bar item); the dashboard opens on demand from the tray/popover. Mirrors the Swift
  app (`ShedDesktopApp.swift:26` `.accessory`; `AppModel.swift:750/991/1395` flips `.regular`↔`.accessory`,
  all `!testMode`-guarded). **Test mode keeps `main` shown + never flips** — else the hidden webview never
  mounts → `ui_report` never fires → `wait_until(current_pane)` times out.
- **"Check for Updates…" = a disabled placeholder** in the popover footer (no Tauri updater until the flip;
  Sparkle is Swift-only) — greyed + a tooltip, for visual parity, *if it renders cleanly*; else omit rather
  than ship an awkward dead control.
- **Order = warm-up-first:** B4 → B3 → B1b (headline last, so its screenshot / native-feel checkpoint is the
  finale — the maintainer eyeballs the popover at the end).

**Order + sub-milestones (green per commit):**

| # | Item | Scope |
|---|---|---|
| Batch3.1 | **B4 launch-at-login** | `tauri-plugin-autostart` (the `auto-launch` crate — LaunchAgent/AppleScript, **NOT** `SMAppService`); `loginitem.status`→`{enabled}` (via `app.autolaunch().is_enabled()`) + a **test-mode-guarded** `loginitem.set {enabled}` IPC op + invoke twins; the React "Launch at login" `Toggle` in Preferences→General (Swift `PreferencesView` parity); a harness `loginitem` probe test. Guard the enable so the harness never writes a real login item (mac `auto-launch` writes a real LaunchAgent / may trigger TCC — NOT HOME-scoped). |
| Batch3.2 | **B3 macOS Touch-ID gate** | `objc2` + `objc2-local-authentication` v0.3.2 (macOS-**target-gated** so Linux never pulls them); `#[cfg(target_os="macos")] TouchIdGate: AuthGate` wrapping `LAContext.evaluatePolicy(policy, localizedReason:)` — `biometrics_only` → `…WithBiometrics`, else `…DeviceOwnerAuthentication` (password fallback); **retain the `LAContext` until the reply block fires**; the block lands on an arbitrary thread → bridge to a `oneshot`; `canEvaluatePolicy==false` → `Unavailable` (deny-safe, matching `TouchID.swift:22-24`); preserve the rich `AuthOutcome` (approved/denied/cancelled/unavailable/error), never a bool. Replace `FailClosedGate` in `production_seams()`'s macOS arm. **Deny-safe Rust unit test** mirroring `gate_never_approves_without_real_auth`. Real Touch-ID needs a signed build → **maintainer hands-on** (coupled to notarization + A5). |
| Batch3.3 | **B1b mac rich popover** (headline) | See the design below. `tray.dump` popover-channel = the hermetic content AC; screenshot = a MANUAL maintainer visual-assessment artifact → checkpoint. |
| Batch3.4 | **A5/B7 real build + smoke** | Confirm the **default/release build compiles+runs with the new deps** on mac (render gate covers Linux); refresh the hands-on runbook. The real agent/Touch-ID/login-item smokes stay the maintainer's. |

*Gates for every code sub-milestone (**full set**): `make e2e-tauri` (mac) · `make tauri-test` · `make
core-test` (runs `--features rc`) · `make tauri-test-linux` + `make tauri-build-linux` (the WebKitGTK render
gate — each sub-milestone touches shared files: `lib.rs`/`Cargo.toml`/`tauri.conf.json`/`vite`, so Linux MUST
be gated; the mac e2e alone misses Linux breaks). A new dep needs the tauri `Cargo.lock` refreshed for the
render gate. Always `cd /abs/path` before `make` (cwd-drift no-ops a bare make from a subdir).*

**B1b design (folds the §3.6 panel gotchas — the decided build):**

Parity target: the Swift `MenuBarContentView` — a header (host-agent status dot), a red pending-approval
block (≤3 cards: namespace/op + qualified-shed, approve(`touchid`|`check`)/deny), a running-sheds list (≤6,
`host/name`), a footer (Open dashboard · Preferences… · Check for Updates… · Quit). Width ~300.

- **Separate React entry, NOT the full `App`.** A 2nd `WebviewWindow` loading `index.html` mounts
  `App`/`useUiBridge` → writes the SAME snapshot keys (`pane`/`sheds`/`refresh_token`) → corrupts
  `dashboard.dump`/`current_pane`/the refresh gate (the `ui_report` key-merge does NOT save us — same keys,
  one window-less blob). Fix = **both**: (a) a new Vite entry `popover.html` + `src/popover.tsx` →
  `TrayPopover.tsx` (a compact tree, its own data hooks, **no** `useUiBridge`); (b) **window-label-keyed
  `ui_report`** — add a `window: tauri::Window` param, store `snapshot_by_label[window.label()]`; the
  dashboard readers (`ui.current_pane`/`ui.computed_style`/`ui.modal`/`dashboard.dump`/`agents.dump`/the
  `sheds.refresh` echo) read the `main` label; `tray.dump` reads the `popover` label. Keeps the *within*-window
  key-merge (the Agents pane's `agents` key) intact.
- **Drivability (OS clicks aren't hermetic).** A `tray.show`/`tray.toggle`/`tray.hide` IPC op runs the EXACT
  Rust path the mac tray-icon left-click runs (the analogue of `ui.show_preferences`), so CI can mount +
  assert the popover; `tray.dump` gains a `popover` block (`{connected, running_sheds, pending_approvals}`
  from the popover's window-keyed snapshot) = the content AC. The **screenshot is manual** (`screencapture`
  is full-display + TCC-gated on mac).
- **Tray builder (macOS).** `show_menu_on_left_click(false)` (MANDATORY — defaults true; else left-click opens
  both menu + popover); `on_tray_icon_event` toggles the popover on ONE click edge (`button_state`
  `Up`|`Down` fires twice/click → dedup on one edge); anchor via `tauri-plugin-positioner` (TrayCenter;
  forward `on_tray_icon_event` into `positioner::on_tray_event`). The native menu stays for **right-click** as
  a fallback (the landed B1 menu) **IF** `on_tray_icon_event` fires with a menu attached; if it doesn't, mac
  goes popover-only (the popover footer already carries those actions) — Linux keeps its attached menu
  regardless. Dismiss-on-blur: popover `WindowEvent::Focused(false)` → `hide`.
- **`tauri.conf.json`:** add a `popover` window — `visible:false`, `decorations:false`, `transparent:true`,
  `skipTaskbar:true`, `alwaysOnTop:true`, `resizable:false`, sized ~320×dynamic, `url:"popover.html"`. Its own
  **capability** (`capabilities/popover.json`, scoped to the `popover` label — `default.json` is `main`-only).
- **ActivationPolicy (role-aware, `!test_mode`-guarded).** `Regular` when `main` shows, `Accessory` when the
  last normal window hides; production launches `.accessory`. Guard EVERY flip on `test_mode` + keep `main`
  shown in test mode.
- **Content:** `TrayPopover.tsx` mirrors `MenuBarContentView` via the existing hooks — `connected =
  gateNs.length>0` (`connected-changed`), `list_sheds` (running, ≤6), `approvals_list` (≤3, approve/deny via
  `approval.decide`). Footer reuses the existing emit paths (`ui.show_window`/`navigate`, `show-preferences`);
  "Check for Updates…" is a **disabled** row. Refetch on the coordinator events + on show; report rows via the
  window-keyed `ui_report` for `tray.dump`.
- **Linux unchanged** — the landed native menu (Tauri emits no Linux tray click events / no popover).
  macOS-only surface.

**⚠️ Panel fold (Batch 3, 2026-07-06 — Codex + Kimi + CodeRabbit, all three converged). Load-bearing
corrections that CHANGE the shape of the code above — folded before any B3/B4/B1b code:**

*B1b — the design sketch above is corrected by these:*
- **[BLOCKING · CR + Kimi] Create the `popover` window PROGRAMMATICALLY, mac-only — NOT a static
  `tauri.conf.json` entry.** A window in `app.windows` is created on EVERY platform at startup, so a shared
  transparent/`alwaysOnTop` 2nd webview loading `popover.html` under headless Xvfb + a multi-page Vite build
  would risk breaking the WHOLE `tauri-linux` render gate (every `--target tauri` test), not just a popover
  test — and Tauri v2 `WindowConfig` may not even honor a `url` field. → Build it in `#[cfg(target_os =
  "macos")]` setup near `tray::build` (`lib.rs:576`) via `WebviewWindowBuilder::new(app, "popover",
  WebviewUrl::App("popover.html".into()))` (borderless/transparent/skipTaskbar/`alwaysOnTop`/hidden). Linux
  blast radius = 0, mirroring how `approval.rs` keeps the native gate `#[cfg(target_os=…)]`.
- **[BLOCKING · Kimi] The popover footer needs NEW invoke commands — it can't "reuse the emit paths."**
  `TrayPopover` is a DIFFERENT webview: it can't call IPC ops (harness-only) nor emit the Rust→main events the
  dashboard listens for. Add small Tauri commands `open_dashboard` (present main + `emit("navigate",
  {pane:"sheds"})`), `open_preferences` (present main + `emit("show-preferences")`), `app_exit`
  (`app.exit(0)`); the footer `invoke`s them; expose them to the popover capability.
- **[BLOCKING · Kimi + CR] The `ui_report` window-keying is ONE atomic refactor of ALL readers.** `UiState` →
  `snapshots: HashMap<String,Value>`, the key-merge applying WITHIN a label; in the SAME commit migrate every
  reader to the `main` label — `ui.current_pane`/`ui.computed_style`/`ui.modal` (`ipc.rs:167-170`),
  `dashboard.dump` (`:188-190`), `agents.dump` (`:522-537`: `pane`+`agents`), the `sheds.refresh` echo
  (`state.rs:32-34` read at `ipc.rs:271,278`), plus `Handler::ui_get` (`ipc.rs:157`) + `ui_report`
  (`lib.rs:46`) taking a `window: tauri::Window`. Keep the within-`main` merge (shell + Agents both report to
  `main`). Regression gate = `test_tauri`/`test_dashboard`/`test_shared` green at BOTH targets.
- **[HIGH · Kimi + CR] `tray.show`/`tray.toggle` must SHOW *and position*** (`move_window(TrayCenter)` via
  positioner), sharing ONE `#[cfg(macos)]` helper with `on_tray_icon_event`. But TrayCenter needs a tray-rect
  cached from a REAL `on_tray_icon_event`; a hermetic `tray.show` with no prior OS click positions at a default
  origin — fine for the `tray.dump` content AC, but **the manual screenshot needs a real tray click first**
  (runbook note).
- **[HIGH · Kimi] Dismiss-on-blur must gate on `label=="popover"`** in the `RunEvent::WindowEvent` handler
  (add a labeled `Focused(false)` arm beside the existing `CloseRequested`, `lib.rs:586-595`) — else a
  `Focused(false)` on `main` hides the dashboard.
- **[HIGH · Kimi] Spike `on_tray_icon_event`-fires-with-menu-attached FIRST (mac).** Log the event while
  keeping the menu; if left-click doesn't fire → mac goes popover-only (footer carries the actions); if it
  fires → keep the menu for right-click + `show_menu_on_left_click(false)`. Linux keeps its menu regardless.
- **[MED · Kimi] The `popover` window won't auto-resize to content** (Tauri ≠ SwiftUI's content-sized frame).
  First pass: a generous fixed height (~600) + scrollable content; a Rust↔JS resize protocol is a follow-up.
- **[MED · Kimi] `TrayPopover` fetches `list_sheds` itself** on mount/show (no `useUiBridge` → no `refresh`
  event; `connected-changed`/`approvals-changed` don't imply a shed-list change).
- **[MED · Kimi + CR] `capabilities/popover.json`** (scoped `["popover"]`, NOT added to `default.json`) needs
  `core:default` + **`core:event:default`** (else no coordinator events) + the new footer commands. Define the
  `tray.dump` shape: `{present, items, popover:{connected, running_sheds, pending_approvals}}`; the popover
  reports its rows under a `tray` key via the window-keyed `ui_report`.
- **[NTH · CR + Kimi] Multi-page Vite:** `build.rollupOptions.input = { main:"index.html",
  popover:"popover.html" }` (keep `emptyOutDir`); verify `dist/popover.html` emits, and that the disabled
  Check-for-Updates row COMPILES in the Linux popover bundle (rides the render gate) even though Linux never
  shows it.

*B3 — the design sketch above is corrected by these:*
- **[BLOCKING · CR] The `!Send` `LAContext` can't be held across the `await`.** `AuthGate::gate` is
  `#[async_trait]` → the future is boxed `+Send`, but `Retained<LAContext>` is `!Send`. Move the `LAContext`
  INTO the completion block and `await` only the `oneshot::Receiver` (which IS `Send`); never hold it across
  the await. (Amends "retain until the reply block fires" — retain by *moving into* the block, not across the
  async boundary.)
- **[BLOCKING · CR + Kimi] The deny-safe unit test must NOT fire a real biometric prompt.**
  `canEvaluatePolicy` returns TRUE on any Touch-ID Mac (incl. a signed runner), so calling the real `.gate()`
  would trigger a live prompt/hang. Factor a **test seam** (inject the can-evaluate decision and/or the
  evaluate closure — the A1 `read_peer_uid`/`peer_trusted` pattern) so the deny-safe assertion covers
  `can_evaluate==false → Unavailable` + the error branches WITHOUT touching real biometrics. `Approved`/
  `Denied` need the signed A5 smoke.
- **[SHOULD · CR + Kimi] objc2 deps go in `[target.'cfg(target_os="macos")'.dependencies]`** (mirror the
  `zbus` Linux block, `Cargo.toml:50-51`) — NEVER global `[dependencies]`. Concretely: `objc2-local-
  authentication` `features=["LAContext","LAError"]`, `objc2-foundation` `["NSString"]` (0.3.2 already
  locked), `block2` (the completion block; 0.6.2 present). Policy values are **constants**
  (`kLAPolicyDeviceOwnerAuthenticationWithBiometrics` / `…DeviceOwnerAuthentication`) via `LAPublicDefines`,
  not enum variants. **Version compat verified:** `objc2-local-authentication` 0.3.2 wants `objc2
  >=0.6.2,<0.8` and the lock has `objc2 0.6.4` → no duplicate `objc2`.

*B4 — refinements:*
- **[SHOULD · CR + Kimi] Consider guarding `loginitem.set` on macOS ONLY.** On the shipped Linux target
  `auto-launch` writes a `.desktop` under the throwaway `$XDG_CONFIG_HOME/autostart` (fully hermetic — the
  harness redirects XDG), so `set` can be driven + round-tripped (enable→status→disable) there, exercising the
  op on the platform that SHIPS it; only macOS's real-LaunchAgent/TCC write needs the guard. `loginitem.status`
  must catch `auto-launch` errors → `{enabled:false}` (never crash). *Confirm auto-launch honors
  `$XDG_CONFIG_HOME` on Linux before relying on the round-trip.*
- **[MED · Kimi] Naming + placement:** IPC ops `loginitem.status`/`loginitem.set`; invoke twins
  `loginitem_status`/`loginitem_set` (like `ssh_prefs_get`/`set_ssh_approval`). Add a **"General" section at
  the TOP** of the React Preferences (before Terminal) with the always-visible "Launch at login" `Toggle`
  (Swift `PreferencesView.swift:24-27` parity).
- **[note · Kimi] Plugin vs raw crate:** keep `tauri-plugin-autostart` (correct exe/`.app`-path resolution via
  `app.autolaunch()`) over raw `auto-launch` (hand-built app-path); verify `tauri-build-linux` after adding.

*Cross-cutting:*
- **[BLOCKING · Kimi] Guard EVERY ActivationPolicy flip + the login-item write on `!test_mode`.** An unguarded
  `.accessory` at launch can leave `main` unmounted → `ui_report` never fires → `wait_until(current_pane)`
  times out across e2e. Keep `main` shown in test mode; add a `lib.rs` unit test that `setup` doesn't flip the
  policy under `test_mode`.
- **[SHOULD · Kimi] Spike each new dep against the render gate** (`make tauri-build-linux`) BEFORE layering
  code — positioner/autostart are cross-platform official plugins (should compile on Linux) but the gate is
  the only proof.
- **[NTH · CR] Plan line-refs are approximate** (point-in-time vs `37e962b`) — grep the symbol, don't trust
  the number.

**Codex confirmed all the above + added these (all three reviewers now folded):**
- **[BLOCKING · Codex] The B4 test-mode guard must cover `disable()` too, not just `enable()`** — both mutate
  host state. **⚠️ Contradiction (Codex vs CR/Kimi), RESOLVED by platform-split:** Codex says *never* touch the
  autostart backend in test mode; CR/Kimi say *do* the Linux round-trip (it's hermetic). Reconcile by platform
  — **macOS test mode: guard BOTH `set(true)`/`set(false)`** (an in-memory cell; never the real LaunchAgent/TCC);
  **Linux test mode: DO the real `auto-launch` round-trip** (the harness redirects HOME + XDG for the subprocess
  targets, so the `.desktop` write is contained → hermetic AND exercises the shipped platform). *Verify the
  harness's HOME/XDG redirect actually contains auto-launch's write path before relying on the Linux round-trip;
  if not, fall back to the in-memory cell on Linux too.* (Maintainer: a coverage refinement, not a direction
  change — I default to the platform-split.)
- **[BLOCKING · Codex] The React "Launch at login" toggle must use a THROWING invoke (or reconcile from
  `loginitem.status`).** `bridge.ts`'s default `invoke` swallows errors (`bridge.ts:45`) → a failed/guarded
  `set` would vanish and leave the toggle lying about the real state. Mirror `applySsh` (`App.tsx:596`):
  optimistic-set → persist → re-read `loginitem.status` → reconcile.
- **[SHOULD · Codex] ActivationPolicy needs ONE Rust path.** Two "show main" helpers exist —
  `present_main_window` (`ipc.rs:84`) + `tray::show_main` (`tray.rs:65`); if only one flips macOS to `Regular`
  the tray + IPC paths diverge. Consolidate show-main-and-flip into one helper both call; the `Accessory`
  revert keys off the last NORMAL window — the `popover` is NOT a normal window (exclude it). Guard every flip
  on `!test_mode`.
- **[SHOULD · Codex] objc2 features:** include `LABase` alongside `LAContext`/`LAError`/`block2`;
  `objc2-local-authentication` 0.3.2 has `block2` as an OPTIONAL feature → enable it explicitly.
- **[NTH · Codex] `TrayPopover` filters running sheds explicitly** — `list_sheds` returns ALL statuses; Swift
  shows only `.running`, capped at 6 (`MenuBarContentView.swift:70`). Filter before rendering + before the
  `tray.dump` report.
- **[NTH · Codex] Stale §3.6 wording fixed** — "B4-autostart … macOS `SMAppService`" corrected to `auto-launch`
  (Batch-3 already states it; the §3.6 line could mislead an implementer).

**Codex (2nd, deeper pass) added these B1b/B3 refinements:**
- **[BLOCKING · Codex] `tray.show`/`tray.toggle` needs a test-mode fallback POSITION.** `tauri-plugin-
  positioner` learns the tray rect ONLY from a real `on_tray_event`; an IPC-driven `tray.show` (no prior OS
  tray event) makes `TrayCenter` FAIL ("Tray position not set"), not just mis-place. For the hermetic drive
  path, fall back to a deterministic position (a fixed origin / `TopRight`) when no tray rect is cached; a real
  tray click still uses `TrayCenter`.
- **[BLOCKING · Codex] Menu-bar-first launch — concrete strategy (avoid the render-gate hang).** Tauri
  auto-creates config windows BEFORE setup; a config `main.visible=false` makes the harness's
  `wait_until(current_pane)` HANG (`conftest.py:107`) — a never-shown WebKitGTK window may not report. So KEEP
  `main` visible in `tauri.conf.json`; in PRODUCTION only (`!test_mode`) hide `main` + set `.accessory` in Rust
  right after tray build (menu-bar-first; the WKWebView keeps running while hidden, so the popover's data still
  flows). Test mode: `main` stays shown, no flip.
- **[SHOULD · Codex] The popover window is OPAQUE, not transparent.** Swift paints an opaque
  `windowBackgroundColor` panel (`MenuBarContentView.swift:96`); Tauri `transparent:true` on macOS needs
  `macOSPrivateApi` + has caveats. Use opaque borderless (`decorations:false`, `transparent:false`; a solid
  rounded surface via CSS) — matches Swift + keeps the render gate simple.
- **[SHOULD · Codex] objc2 calls are selector-style, not Swift-shaped.** Don't expect
  `evaluatePolicy(policy, localizedReason:)`; the generated names are selector-derived + take `block2` blocks,
  and `NSError**` surfaces as `Result<_, Retained<NSError>>` (not `&mut NSError`). Direct macOS-target deps:
  `objc2` + `objc2-foundation` + `block2` + `objc2-local-authentication` (mirror the `zbus` Linux block).
  Confirm exact names via `cargo doc` at impl time.
- **[NTH · Codex] Map LocalAuthentication errors into the rich `AuthOutcome`** (`traits.rs:49` preserves
  non-approved outcomes): not-enrolled / passcode-missing / unavailable → `Unavailable`; user/system/app cancel
  → `Cancelled`; auth-failed → `Denied`; unknown NSError → `Error`.
- **[NTH · Codex] `tray.dump` popover block includes `visible` + logical row counts** so "shown-but-not-yet-
  reported" is distinguishable from "hidden" in the hermetic test.
- **✓ Confirmed:** the harness redirects `HOME` + `XDG_CONFIG_HOME` to the throwaway dir (`ui.py:280-284`), so
  the B4 Linux `auto-launch` round-trip IS contained → hermetic (the platform-split's Linux half is safe).

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
| B1 | Tray — Linux menu + drivability ✅ **LANDED** (`900780e`) | `lib.rs`, `App.tsx`, `bridge.ts`, `ipc.rs` | `tray.dump`; own report channel | both | high |
| B1b | Tray — macOS rich popover ← **Batch3.3** (§3.7) | `lib.rs`, `tray.rs`, `state.rs`, `ipc.rs`, `tauri.conf.json`, `TrayPopover.tsx`, `vite.config.ts`, `capabilities/` | popover positions; window-keyed report channel; `tray.dump` popover block; manual screenshot | macOS | high |
| B3 | macOS Touch-ID gate ← **Batch3.2** (§3.7) | `approval.rs`, `Cargo.toml` | deny-safe unit test; manual smoke | macOS | med |
| B2 | Agents/RC ✅ **LANDED** | `shed-core/rc.rs`, `terminal.rs`, `shed-app/{rc.rs,backend.rs}` (feat `rc`), `ipc.rs`, `lib.rs`, `App.tsx`, `bridge.ts`, harness | `test_agents` at `--target tauri`; `cargo test -p shed-app --features rc` | both | high |
| B5 | macOS notifier ✅ **LANDED** | `approval.rs` | osascript `OsaNotifier` posts/withdraws | macOS | low |
| A4 | D-Bus withdraw ✅ **LANDED** (`bf48a83`) | `approval.rs`, `Cargo.toml` | id-captured unit test | Linux | low |
| B4 | Prefs — SSH policy/TTL ✅ **LANDED** (`e19f08f`) · launch-at-login ← **Batch3.1** (§3.7) | `App.tsx`, `bridge.ts`, `lib.rs`, `Cargo.toml` | policy drives; `loginitem` probe | both | low |
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
