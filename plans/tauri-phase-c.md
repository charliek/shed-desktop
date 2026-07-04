# Tauri Phase C — menu-bar + Agents/RC + approval-spine hardening

*The "can the Tauri client replace the Swift mac app **and** the GTK Linux `.deb`?" evaluation.*

> **Panel-reviewed (2026-07-04, Codex + Kimi + CodeRabbit).** The direction held; the details were
> reshaped. Verified in-tree: **`objc2-local-authentication` v0.3.2 exists** (the mac gate is a ready crate,
> not hand-rolled bindings); **Tauri emits no tray click events on Linux** (`tauri-2.11.5/src/tray/mod.rs`),
> so the tray is a **platform split**, not one portable design.

## Status — pick up here (2026-07-04)

**Branch `tauri-phase-c`** (off merged `feat/rust-core` = `c10d386`). **5 of ~11 milestones LANDED, all
gates green** (shed-app 65 · tauri crate tests 10 · e2e-tauri 45 · WebKitGTK render gate 47):
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

**Outstanding design decisions to settle at the top of the next session (before/while building B2):**
1. **RC extraction boundary** — pure classify / `normalizeRcPrompt` / argv / DTOs → **`shed-core`**;
   process / SSH / session management → **`shed-app`** behind an `rc = ["tokio/process"]` feature (so
   `shed-gtk` doesn't compile SSH-spawning it never uses). Panel-confirmed; lock the exact module layout.
2. **Test-mode session store** (`rc.inject_test`) — the analog of `AlwaysApprovedGate`/`FakeNotifier`;
   `test_agents.py` depends on it (a synthesized ready session). Where it lives + its seam.
3. **SSH shell-out** — RC launch runs `ssh … shed-ext-rc create --wait`; the Tauri backend needs the SSH
   setup + the `shed-ext-rc` binary. Decide the process-runner seam (test fake vs real).
4. **No Swift-FFI in Phase C** — the Swift app keeps its own `RemoteControl.swift`; bridging `shed-app::rc`
   to Swift is a Phase-4 milestone.
5. **B1b tray** — Tauri webview popover vs a native-Swift mac menu: decide after the B1b spike (the user's
   Swift interest is the *menu-bar*, not the gate, which is settled as objc2).

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

### 3.2 B2 — The Agents / RC pane (a **5-part port**, not a retag)

**Parity target** — the Swift launcher (`AgentsView.swift` + `AgentLaunchSheet.swift`; ops
`rc.classify/list/launch/kill` in `IPCHandlerImpl.swift`; runtime in `AppModel.swift:998-1110`; models in
`ShedKit/RC/RemoteControl.swift`): launch a `claude-rc` (REPL, optional prompt) or `shell` in a shed via
SSH `shed-ext-rc create --wait`, poll sessions, classify pane output into states, console (tmux attach),
kill. The Tauri `AgentsPane` is a `SEED_AGENTS` stub. Per guardrail #3 (grounded by the panel):

1. **Pure RC logic → `shed-core`**: the classifier regexes, `normalizeRcPrompt` (2000-byte cap +
   control-char reject), `createArgv`/`sshArgv`, and the RC-Convention-v2 DTOs — protocol-level, hermetic.
2. **Process/SSH/session management → `shed-app`** behind a **`rc = ["tokio/process"]` Cargo feature** so
   `shed-gtk` (which links `shed-app`) doesn't compile SSH-spawning it never uses — **plus a test-mode
   in-memory session store + `rc.inject_test`** (the analog of `AlwaysApprovedGate`/`FakeNotifier`; the mac
   app synthesizes a ready session under test mode, `AppModel.swift:1016-1030,1074`, and
   `test_inject_legacy_session_renders`/`test_launch_list_kill` depend on it).
3. **Tauri IPC ops** `rc.classify/list/launch/kill/inject_test` (`ipc.rs`) + invoke commands + a live
   session table / launch form / console+kill buttons in the pane.
4. **Harness**: a `_RcOps` mixin on `TauriClient` (mirroring `_ApprovalOps`; the `rc_*` methods live on
   `ShedDesktop` only today, `client.py:269-324`).
5. **Marker**: `needs_agents = {mac, tauri}` in `_marks.py` (mirroring `needs_approvals`); retag
   `test_agents.py` from `mac_only` + a target-appropriate client.

**The Swift-FFI adoption of `shed-app::rc` is a real Phase-4 export milestone, not free — Phase C does NOT
bridge `rc` to Swift** (the Swift app keeps its `RemoteControl.swift` during the dual-ship window).

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

### 3.5 B5 — macOS approval notifier (**new — panel-surfaced parity gap**)

`production_seams()` returns `NoopNotifier` on non-Linux, so the Tauri **mac** app posts **no** approval
banners — vs the Swift `SystemNotificationPresenter` (with approve/deny actions). **DECIDED: add it** — a
macOS `Notifier` (start with `tauri-plugin-notification`; escalate to `UNUserNotificationCenter` via objc2
if the plugin can't carry approve/deny action buttons), mirroring the Swift presenter. Posts on a pending
prompt, withdraws on resolve; a notification action routes back through `notification.invoke` (the same
path the pane uses). Full mac parity — the maintainer is building toward a possible mac replacement, so the
banners are in scope.

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
| A1 | Peer-UID check | `host_agent.rs` | seam tests green; untrusted state surfaced | both | med |
| A2 | Gate dedup | `coordinator.rs` | one-prompt-per-id; deny still evicts; marker cleared all paths | both | low |
| A3 | Clear grants on disconnect | `coordinator.rs` | eviction test green | both | low |
| B1 | Tray (mac popover / Linux menu) | `lib.rs`, `App.tsx`, `bridge.ts`, `ipc.rs` | `tray.dump`; own report channel | both | high |
| B3 | macOS Touch-ID gate | `approval.rs`, `Cargo.toml` | deny-safe unit test; manual smoke | macOS | med |
| B2 | Agents/RC | `shed-core` rc, `shed-app` rc (feat), `ipc.rs`, `App.tsx`, harness | `test_agents` at `--target tauri` | both | high |
| B5 | macOS notifier | `approval.rs`, `Cargo.toml` | notifier posted (or documented delta) | macOS | low |
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
- **macOS tray implementation (B1) — Tauri now; native-Swift menu is a data-driven option for the flip.**
  Linux must be Tauri regardless. The Tauri webview popover is reversible + evaluate-first; the **S1 spike**
  measures the mac popover's native feel. If it's not good enough for the mac replacement, a native
  `NSStatusItem` + reused `MenuBarContentView` becomes a *targeted* mac upgrade — but that carries a Swift
  toolchain + a bidirectional Rust↔Swift data bridge (the menu needs the coordinator's data) + two tray
  impls to maintain + reverses guardrail #3, so it's justified only if the spike shows the webview popover
  falls short. Decide after S1, with data.
- **Panel review** — **DONE** (this revision folds it).
