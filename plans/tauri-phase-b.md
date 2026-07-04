# Tauri Phase B — the credential-approval spine, on Rust (implementation plan + threat model)

Status: **PLAN — panel-folded (Codex + Kimi K2.6 + CodeRabbit, 2026-07-03).** Standalone: a reviewer needs
no prior chat context. This is the detailed, security-focused plan for **Phase B** of
[`tauri-desktop.md`](tauri-desktop.md) (read it for the 3-phase shape + locked decisions). Phase A is
**shipped** (PR #27 → `feat/rust-core`); this branch (`tauri-phase-b`) is stacked on `feat/rust-core`.
One decision remains the maintainer's (**AuthGate** mechanism); **C1** is now resolved (§4). Panel
findings are folded throughout; the highest-impact were the coordinator concurrency model (§2.2), a
previously-unspecified timestamp-parsing surface (§2.1/§2.2), a second gate-weakening op surface (F13),
and that the marquee TOCTOU edge had no deterministic test (§6).

> **Provenance.** Every mac file:line anchor below was read directly (`Sources/ShedKit/Approval/*`,
> the `AppModel` coordinator, `Sources/ShedKit/Net/*`, the Rust `core/*`, the host-agent Go, and the
> harness). The port is a *faithful re-implementation* of a shipped, tested Swift spine — not a
> greenfield design — so the plan is mostly "port X to Rust location Y, preserving invariant Z".

### At a glance
Three moves: **domain + codec + policy → `shed-core::approval`** (pure), **client + coordinator + audit +
seam-traits → `shed-app`** (stateful), **IPC ops + AuthGate/Notifier impls + panes → `tauri/`** (platform).
The control-token FSM (C2) is already in Rust — only a UDS client + a minter + one wiring line remain.
The security crux is the coordinator's concurrency model (§2.2) and the fail-closed catalogue F1–F13 (§1.3).

| Swift source | → Rust destination |
|---|---|
| `ApprovalModels.swift` | `core/shed-core/src/approval/models.rs` |
| `HostAgentProtocol.swift` | `core/shed-core/src/approval/protocol.rs` |
| `PolicyEngine.swift` | `core/shed-core/src/approval/policy.rs` |
| `HostAgentClient.swift` | `core/shed-app/src/host_agent.rs` |
| `HostAgentTokenMinter.swift` / `ControlTokenProvider.hostAgent` | `core/shed-app/src/token_minter.rs` |
| `AppModel` M3 coordinator (`:1144–1381`, `:185–262`) | `core/shed-app/src/coordinator.rs` |
| `AuditStore.swift` | `core/shed-app/src/audit_store.rs` |
| `NotificationPresenter.swift` / `TouchID.swift` | `core/shed-app/src/{notifier,gate}.rs` traits + `tauri/src-tauri/src/approval.rs` impls |
| `DateFormatting.swift` (ISO-8601 parse/format) | `core/shed-app/src/timefmt.rs` (**new work item — §2.1**) |
| `IPCHandlerImpl` approval ops | `tauri/src-tauri/src/ipc.rs` dispatch |

---

## 0. What Phase B delivers

Port the credential-**approval spine** from the mac Swift app into the shared Rust core so the **Tauri
(Linux) client shows + gates approvals** too, at Mac parity (except biometrics). The security-sensitive
half of the app the mac ships and the Linux clients (GTK + Tauri) currently lack.

**The leverage (already in Rust — do NOT rebuild):**
- `core/shed-core/src/token.rs` — the **control-token FSM** is done + tested: `TokenMinter` trait
  (`async fn mint(&self, server: &str) -> Result<MintedToken, ShedError>`), `ControlTokenProvider`
  (cache / 2h-refresh-window / single-flight / fail-closed / empty-token guard).
- `core/shed-core/src/http.rs` — `Client::new(base_url, server_name, static_token, pin, minter:
  Option<Arc<dyn TokenMinter>>)` already **builds the provider, sources the Bearer from it, and does
  `invalidate()` + retry-once on a 401** (`http.rs:80,89-90,104-105,139-150`). This IS the mac model.
- `core/shed-app/src/backend.rs` — the multi-host `Backend` (poller/reachability/lifecycle/create),
  built Phase A; today it constructs each `Client` with `minter = None` (`backend.rs:82`).
- The host agent already speaks `token.get`/`token.response` on `main` (§C1).

So **C2 (per-server control-token minting) is small**: build a Rust `HostAgentClient` (needed for
approvals anyway), add a `TokenMinter` impl that calls its `token.get`, and pass `Some(minter)` per
secure server. The caching, refresh, and 401-retry are already wired.

---

## 1. Threat model

The whole point of this phase is a **privilege boundary**, so the threat model is the spec, not an
appendix.

### 1.1 Assets (in decreasing sensitivity)
1. **Real credentials** — SSH keys, AWS creds, Docker creds. Held **only** by `shed-host-agent`. The
   app/webview **never** sees key material — only request *metadata* (namespace/op/shed/detail) and a
   yes/no authority. (Invariant, unchanged from mac: "the app deliberately holds none.")
2. **The user's auth secret** — the Touch-ID/password/PAM factor behind the AuthGate. Entered into the
   **OS** auth prompt; never into the app, never into the webview, never over IPC.
3. **Control tokens** — short-TTL, server-scoped, minted on demand. Live only in `ControlTokenProvider`'s
   in-memory cache; never persisted, never returned over the drivability IPC.
4. **Approval-decision authority** — the app *decides* approve/deny; the agent *enforces*. A forged or
   coerced decision is the primary attack goal.
5. **The audit log** — append-only integrity; a defender's record of what was approved.

### 1.2 Trust boundaries
| # | Boundary | Direction of trust | Enforcement |
|---|----------|--------------------|-------------|
| TB1 | React **webview** ⟷ Tauri **Rust backend** (`invoke` + the newline-JSON IPC socket) | Backend does **not** trust the webview with secrets; the webview is a *view + intent source*, not a credential holder | Strict CSP (Phase A: no external hosts); the gate runs **backend-side**; no token/secret in any `invoke`/IPC result |
| TB2 | Rust backend ⟷ **shed-host-agent** (UDS) | The agent is the key-holder + policy root; the app is a *delegated decider* | UDS is `0600` in a `0700` dir (owner-only); last-writer-wins `hello`; **fail-closed** on every unhappy path |
| TB3 | Rust backend ⟷ **shed-server** (HTTPS) | Server trusted by *network*, not by app | Leaf-cert pinning (`tls.rs`); bearer = short-TTL minted control token; a 401 → invalidate+re-mint, never a static downgrade |
| TB4 | External **driver** ⟷ the drivability IPC socket | A driver has the *same* authority as the user clicking (this is the drivability North Star) | `policy.set` is **test-mode-gated**; the socket is owner-only in prod; **no secret material** is ever exposed on it |
| TB5 | Rust backend ⟷ **OS auth** (PAM/polkit) — the AuthGate | The OS owns the factor; the app only learns approved/denied | The gate helper runs the native prompt; the app gets a rich **enum**, never the secret |

### 1.3 Invariants (the fail-closed catalogue — each is a required test)
- **F1 — No credentials in the webview / on IPC.** `approvals.list`, `activity.list`, every op result
  carry metadata only. No control token, no key, no auth factor crosses TB1/TB4. *(Assert: op results
  contain no token/secret fields.)*
- **F2 — Not connected ⇒ decisions dropped ⇒ agent denies.** If the `HostAgentClient` is not connected
  when a decision is made, the response is a no-op; the agent fails closed. We **never** queue a
  decision for later replay. *(Port of `HostAgentClient.respond` no-op-if-disconnected.)*
- **F3 — Disconnect drops ALL pending.** On host-agent disconnect, every pending prompt is withdrawn +
  cleared — the user can't act on, or persist a rule from, a stale prompt. *(AppModel:1191-1198.)*
- **F4 — Expired ⇒ no late approve.** A request past `expires_at` cannot send an approve — re-checked
  **before** the gate *and* **after** the async gate returns (it may have expired while the prompt was
  up). *(AppModel:1228 + 1243-1244.)*
- **F5 — AuthGate closed by default.** Gate `unavailable` / `error` / `cancelled` / `denied` ⇒ **not
  approved**. Biometrics-only on Linux (no sensor / unconfigured PAM) ⇒ fail-closed. The gate returns a
  rich enum (never a bare `bool`) so "couldn't ask" is distinguishable from "user said no" — both
  deny-safe, but audited differently.
- **F6 — Mint failure ⇒ send NO token.** A `token.get` error (or empty token) ⇒ the client sends no
  bearer; a secure server then 401s → shown unreachable (correct), an open server still works. Never a
  static-token downgrade. *(`token.rs` + `http.rs` already enforce; C2 wires the minter.)*
- **F7 — Deny supersedes a live grant.** A deny evicts any live session grant for that key, so the
  grant (highest precedence) can't keep auto-approving past the deny. *(AppModel:1252.)*
- **F8 — `policy.set` stays privileged.** The op that installs policy rules from a *driver* remains
  test-mode-gated in production (else a driver auto-approves everything). *(IPCHandlerImpl:289-292.)*
- **F9 — Audit before transmit.** Record the app-side decision *before* sending it to the agent, so an
  approve we sent always has a trail even if we crash mid-write. *(AppModel:1297-1304.)*
- **F10 — Single-resume, no leak.** Each correlated `token.get` continuation resolves exactly once
  (reply | timeout | disconnect); timeouts are armed after registration and cancelled on resolve.
  *(HostAgentClient `pending`/`pendingTimeouts` + `removeValue` guard.)* In Rust this is *structural* — a
  `oneshot::Sender` is consumed on send and `HashMap::remove` hands it to exactly one path — but keep the
  timeout-after-register ordering.
- **F11 — Trusted socket path.** The host-agent UDS is also the transport for the short-lived control
  token during `token.get`, so the `0600`-in-`0700` permission (TB2) is the enforcement boundary. Before
  `connect()`, verify the target is a real socket, not a symlink (guard against socket-squatting in a
  shared `$XDG_RUNTIME_DIR`/`/tmp`); prefer `SO_PEERCRED` peer-UID validation where available. *(New —
  Linux surface the mac path didn't face; the mac agent already refuses to bind over a live socket.)*
- **F12 — Per-shed rules never silently widen.** A per-shed rule persists its `server` **verbatim**:
  `""` (the single/unnamed server) is **not** collapsed to `nil`, because `nil` means *any* server — so a
  single-server grant can never widen to other servers. A Rust `Option<String>` port that maps `""`→`None`
  on persist would pass most tests yet regress isolation. *(AppModel:250-255; PolicyEngine:26;
  `test_per_server_shed_isolation`.)*
- **F13 — Policy *weakening* is privileged, not just `policy.set`.** `ui.set_ssh_approval` is a **second**
  gate-weakening surface (set SSH to `always-allow`, or method `prompt` → `rebuildPolicy` installs an
  auto-approve/no-gate rule, *bypassing the AuthGate entirely* without ever calling `approval.decide` —
  AppModel:185-195, ApprovalModels:220). On mac the native SwiftUI prefs window is the trust boundary; on
  Tauri the **webview is the least-trusted surface** (TB1). Posture (**maintainer-flagged, §9**): the
  webview is trusted for the user's *own* preference changes because the strict CSP blocks remote content
  and a compromised in-process webview already owns the process — but `ui.set_ssh_approval`/`policy.set`
  reaching this from the *drivability* socket stay owner-only (prod) and `policy.set` stays test-mode-gated
  (F8). A stronger option (defer): gate a *weakening* change behind the AuthGate itself.

### 1.4 Adversary scenarios (and why each is contained)
- **Compromised/buggy frontend tries to auto-approve.** It can only call `approval.decide`; for a
  biometric-gated request that still runs the **backend-side** AuthGate (F5), which it can't satisfy or
  bypass, and it can't read credentials (F1). For a `prompt`/`none`-gate request, `decide` == the user
  clicking — by design; the mitigation is policy (sensitive namespaces gate) + `policy.set` gating (F8).
- **Driver on the IPC socket.** Same surface as the frontend; `policy.set` gated (F8); owner-only socket.
- **Malicious shed-server.** Can't obtain credentials (agent-held); cert-pinned (TB3). A forced 401
  triggers an **immediate invalidate + single retry-once** *per request* (`http.rs:147`) — **not** rate-
  limited by the 2h window (that governs only proactive cached refresh, `token.rs:91`). So a persistent-401
  server can cause ≤1 re-mint attempt per client request; bounded by the ~5s poll cadence, but each mint
  is a `token.get` the agent services over SSH — a **mint circuit-breaker** (back off after N consecutive
  failing mints for a server) is a reasonable hardening (defer; note it).
- **Stale/rogue host-agent on the socket.** The app connects to the well-known owner-only path; the
  real agent refuses to bind over a live socket and last-writer-wins protects the channel.
- **Audit tampering.** Out of scope to *prevent* (local file, user-owned), but append-only + host-agent
  cross-log gives two records; document it as a known limitation.

### 1.5 Explicit non-goals / deferrals
- No egress control changes (audit-only, streamed as today).
- Biometrics on Linux (fprintd/WebAuthn) — **deferred**; `biometrics-or-password` maps to native
  password on Linux, `biometrics`-only is **fail-closed** on Linux until fprintd lands.
- The GTK approval pane stays deferred (roadmap M6); shed-core/shed-app changes are **additive** so GTK
  keeps building and its e2e stays green.
- **Defense-in-depth follow-ups (B5 review, not violations under the current threat model — approvals
  flow *to* the credential-holder and no grant/rule can be injected without a real user Approve):**
  (a) a disconnect clears `pending` + `gate_namespaces` but keeps `session_grants`/`extra_rules` (matches
  the mac); clear the gated `ssh-agent` session grants on disconnect too, and land the deferred
  `SO_PEERCRED` peer-UID check (§1's "New") — these become load-bearing the moment peer-UID auth or
  on-disk rule persistence ships, so a reconnected/squatting same-UID agent can't inherit a grant.
  (b) `finish_decide`'s binding check distinguishes a same-id *replacement* but not a byte-identical
  *replayed* frame across a reconnect; trust-direction-safe today, revisit with (a).

---

## 2. Architecture — where each piece lands

Follows the Phase-A seam: **pure protocol → `shed-core`; stateful/I-O → `shed-app`; platform → the
client crate**. The mac `ShedKit`/`AppModel` split maps almost 1:1.

**Files touched (create ⊕ / modify ~):**
- ⊕ `core/shed-core/src/approval/{mod,models,protocol,policy}.rs` + `lib.rs` `pub mod approval;` (~)
- ⊕ `core/shed-app/src/{host_agent,token_minter,coordinator,audit_store,gate,notifier}.rs` +
  `src/traits.rs` (AuthGate/Notifier/Clock/Paths) + `lib.rs` (~)
- ~ `core/shed-app/src/backend.rs` — thread an optional per-server `Arc<dyn TokenMinter>` into
  `Client::new` (the one C2 change; default `None` keeps GTK/tests unchanged)
- ~ `tauri/src-tauri/src/ipc.rs` (10 new ops), `src/lib.rs` (coordinator + client wiring in `setup`),
  ⊕ `src/approval.rs` (AuthGate/Notifier impls + Tauri glue), `src/env.rs` (socket/state paths)
- ⊕ `tauri/ui/src/panes/{Approvals,Activity}.tsx` + approval prefs; ~ `tauri/ui/src/lib/bridge.ts`
- ~ `tools/shedtest/{_marks.py,conftest.py,ui.py,client.py}` (the `--target tauri` generalization);
  `tools/fake-host-agent/fake_host_agent.py` reused as-is
- ⊕ `.github/workflows/*` — the tauri CI leg (B0); ~ `Makefile` if new targets are needed
- Reference (read-only, the port source): `Sources/ShedKit/Approval/*`, `Sources/ShedKit/Net/{ControlTokenProvider,HostAgentTokenMinter}.swift`, `Sources/ShedDesktopApp/{AppModel,IPCHandlerImpl}.swift`

### 2.1 Pure → `core/shed-core/src/approval/` (new module; no I/O, fully unit-testable)
Mirror the `models.rs` defensive-decoder style (`null_default`, `decodeIfPresent`-equivalents) and reuse
`ShedError`.
- **Domain models** (from `ApprovalModels.swift`): `ApprovalRequest` (defensive `server` default),
  `ApprovalDecision`, `DecidedBy`, `AuditEntry` (+ `From<AuditEventFrame>`), `AuditSource`,
  `PolicyAction`, `PolicyGate`, `ApprovalMethod`, `ApprovalScope`, `SshApprovalPolicy`, `PolicyScope`,
  `PolicyRule`, `PendingApprovalItem` (the IPC wire shape w/ inlined request fields), `ApprovalChoice`,
  `SessionGrantKey`, `PolicyDecision`, `TtlShorthand::seconds`, `DEFAULT_APPROVAL_TTL = "2h"`.
- **`HostAgentProtocol` codec** (from `HostAgentProtocol.swift`): `decode(line) -> HostAgentInbound`
  (dispatch on `type`: hello_ack / approval_request / event / ping / token.response / unknown) + the
  outbound encoders (hello, approval_response, pong, **token.get**). Protocol `v = 2`. Wire types:
  `HelloAck`, `AuditEventFrame`, `TokenResponse` (`in_reply_to`, `token?`, `expires_at?`, `error?`).
- **`PolicyEngine`** (from `PolicyEngine.swift`): `decide(req, session_grants) -> PolicyDecision`,
  precedence **session-grant > per-shed(+server) > per-namespace > default → else fail-safe
  `prompt`/`biometrics-or-password`**. Pure; the caller pre-filters valid grants.
- **Ports of** `PolicyEngineTests`, `HostAgentProtocolTests`, the model decode tests → Rust `#[cfg(test)]`,
  **including** a `decode_request_with_missing_server_defaults_empty_string` case (F12/defensive `server`).
- **Note — keep `expires_at`/`ts` as wire *strings* here.** The pure models carry timestamps verbatim (the
  crate stays parse-free, matching `token.rs`'s "timestamp parsing off this crate"); all instant
  comparison/formatting happens in `shed-app` (below). PolicyEngine stays pure (the caller pre-filters
  valid grants by time).

**⚠ New work item — flexible ISO-8601 parse+format (`shed-app/src/timefmt.rs`).** The Rust core has **no**
date parser today (Swift owned it: `token.rs` only ever sees `expires_at_unix: Option<u64>`, already
parsed). Moving the coordinator **and** the token minter into Rust creates three parse/format sites the
port must add — with the mac fail-closed defaults preserved *exactly*:
- `approval_request.expires_at` (string) → a comparable instant at the F4 checkpoints. **Fail-closed
  default (critical):** unparseable → treated as **already expired** (mac: `nil` → `.distantPast`,
  AppModel:1228/1243-1244). A naive `parse().unwrap_or(far_future)` **inverts** this into a never-expiring
  approvable request — a direct security regression. *(Required test: malformed `expires_at` ⇒ no approve.)*
- `token.response.expires_at` (string) → `MintedToken.expires_at_unix` (HostAgentTokenMinter.swift:35-38).
  Skipping it (passing `None`) makes `needs_refresh` always-false (`token.rs:91-96`) ⇒ the token is cached
  and never proactively refreshed, leaning the whole staleness story on the 401 path — the exact class the
  C1 fix addresses. Parse it.
- outbound `ts` (hello/approval_response/pong) + `AuditEntry.ts` → ISO-8601 from "now". The `Clock` seam
  must therefore expose **`now_iso8601()`** too, not only `now_unix()`.
Port `DateFormatting`'s flexible cases (fractional-second+offset, plain `Z`, trailing ` (UTC)` strip;
DateFormatting.swift:26-35) as `#[cfg(test)]`. This is a **distinct** surface from the `models.rs` JSON
defensive-decoders — don't conflate them. Choose `chrono` vs `time` vs a hand-rolled RFC-3339 parser (a
`shed-app` dep, so `shed-core` stays lean); the requirement is *flexible parse + the fail-closed default*.

### 2.2 Stateful/I-O → `core/shed-app` (the keystone; needs the platform-seam traits, which Phase A left as TODO)
- **`host_agent.rs` — the `HostAgentClient` UDS state machine** (from `HostAgentClient.swift`):
  connect → `hello` → backoff-reconnect (0.5→5s), a line-framed reader, `ping`→`pong`, `helloAck`→emit
  connected, correlated `token.get`/`token.response` (`pending: HashMap<id, oneshot>` +
  `pending_timeouts`, single-resume, timeout-after-register), `respond(...)` (no-op if disconnected →
  F2), `fail_all_pending` on disconnect (F10). Async via tokio (mirror `create`'s runtime handle model).
  Emits a `HostAgentEvent` stream (connected / disconnected / frame). **Port *and extend*
  `HostAgentClientTests`** — the Swift suite covers success/error/timeout/disconnect/not-connected but not
  the duplicate/late-reply or reconnect corners; Rust adds those (the exact list is in B1).
- **`token_minter.rs` — `HostAgentTokenMinter`** (impl `shed_core::TokenMinter`): calls
  `HostAgentClient::request_token(server)`; a fail-closed reply (error set / no token) ⇒ `Err` ⇒ F6.
  Mirrors both `ControlTokenProvider.hostAgent` and Swift's `HostAgentTokenMinter`.
- **`coordinator.rs` — the approval coordinator** (from `AppModel`'s M3 section): owns `pending`,
  `session_grants` (`.distantFuture` sentinel for sticky), the `PolicyEngine`, and:
  `handle_approval_request` (decide → auto-respond or queue+notify),
  `decide_approval(id, choice)` (**the async gate**, with F4 pre+post expiry re-checks, F7 deny-evicts,
  sticky vs TTL grant, persist→per-shed rule, then `respond_and_audit` + withdraw),
  `expire_pending` (1s tick → expire-to-deny), `respond_and_audit` (**F9** audit-before-transmit),
  `reevaluate_pending` (on policy change), `valid_grants`, the disconnect handler (**F3**).
- **`audit_store.rs` — the `AuditStore` writer** (from `AuditStore.swift`): append-only JSONL under the
  platform `state_dir`, a locked in-memory tail (bounded, 500) for the Activity feed.
- **Concurrency model (THE crux — panel's top risk; get this exactly right).** The mac coordinator is
  `@MainActor`: `pending`/`session_grants`/`policy` mutate on one serialized executor, and crucially the
  whole post-`await TouchID` block — re-check → mutate grants/rules → `respond` → clear — runs
  **synchronously** there (AppModel:1243-1284), i.e. *atomic* w.r.t. the 1s expiry tick (`:1286-1295`) and
  the disconnect handler (`:1191-1198`). Rust must reproduce that atomicity. **Decision: a single-task
  mpsc *actor*** (owned state, `Command` enum), **not** an ad-hoc `tokio::Mutex` — the Mutex form invites
  two failure modes the panel flagged:
  - **Never `await` the AuthGate inline in the actor loop.** Doing so head-of-line-blocks the queued
    `Disconnect`/`Expire` commands for the whole prompt duration; when the gate resolves, `decide_approval`
    finishes *first* and its re-check still sees `pending[id]` present, so it **persists a session grant /
    per-shed rule from a prompt whose connection already dropped** — violating F3's own contract (F2 stops
    the *wire* approve, but the grant/rule state is already corrupted). Instead use **two-phase**:
    phase-1 (`Decide{id,choice}`) validates presence+expiry and captures the gate params, then **spawns**
    the AuthGate as a separate task; phase-2 re-enters the actor as `GateResolved{id, outcome}` and — in
    one uninterrupted command handler — re-validates presence+expiry, mutates grants/rules, calls
    `respond`, audits, and clears. Between the two phases the actor freely processes `Disconnect`/`Expire`,
    so a request killed mid-prompt is simply gone when `GateResolved` arrives (→ no late approve, no grant).
  - **`respond` must be synchronous + non-blocking.** Mac's `hostAgent.respond` is a blocking `writeAll`
    inside the atomic block (AppModel:1306). In tokio, an `async fn respond` awaited *after* releasing state
    reopens the deny/approve race (the tick fires between re-check and write, sends `deny`, then the late
    `approve` lands — a contradictory double-response). So route `respond` through an
    `mpsc::UnboundedSender` to the `HostAgentClient` writer task: a synchronous, non-blocking send the
    actor makes **inside** the atomic command handler (mirrors mac's sync write).
  - **No lock held across user callbacks.** `reevaluate_pending` collects the IDs to resolve, then resolves
    them as ordinary command steps; `Notifier`/`AuthGate`/audit calls never run while conceptually
    "holding" cross-request state — the actor model makes this structural.
  Getting this wrong silently reintroduces the exact TOCTOU + stale-grant corruption the mac code guards
  against, so it is a required, **deterministically-tested** property (§6, via a *blockable* test gate).
- **Seam traits** (new in `shed-app`; GTK ignores them, Tauri implements them):
  - `AuthGate` — `async fn gate(&self, prompt: AuthPrompt) -> AuthOutcome` where
    `AuthOutcome = { Approved, Denied, Cancelled, Unavailable, Error(String) }` (rich enum, **never
    bool**; F5). **Failure semantics = mac-parity (`stay pending`).** Mac's failed/absent TouchID returns
    `false` and the request is **left pending** for retry-or-expiry (AppModel:1231-1238), *not* denied or
    audited. So any non-`Approved` outcome ⇒ **keep the request pending + surface an error** (the enum
    drives the error *message* + optional local gate-attempt audit detail — **not** a different control
    flow). Tests: one per outcome (`Denied`/`Cancelled`/`Unavailable`/`Error` all keep pending; only
    `Approved` proceeds). **Test impl must be *blockable*** — a `oneshot`/barrier the test releases (not a
    bare always-`Approved`) — so §6 can hold the gate open, expire the request underneath it, then release
    `Approved` and assert *no late approve*. This is what makes the F4 post-gate TOCTOU falsifiable.
  - `Notifier` — `post(req)`, `withdraw(id)`, `on_action`/`on_open` sinks (from `NotificationPresenter`);
    a `FakeNotifier` records posts + lets the harness invoke (drives `notifications.list` /
    `notification.invoke` / `notification.open`).
  - `Clock` — `now_unix()` **and `now_iso8601()`** (the coordinator/minter format outbound `ts`/audit `ts`
    from it — §2.1), injectable so the expiry/TTL/grant/TOCTOU edge-cases are deterministic (mac leans on
    real 1s sleeps; Rust injects the clock + keeps a small real-time smoke for the tick).
  - `Paths` — `state_dir()` (for `audit.jsonl`) / `host_agent_socket()` resolution (shared by GTK + Tauri;
    honors the test env overrides; see §7).
  - `PrefsStore` — persist + load the SSH approval settings (`ssh_method`, `ssh_policy`, `ssh_ttl`, and the
    per-shed `extraRules`), mirroring the mac `PreferencesStore`. **Gap flagged by the panel:** Tauri's
    `prefs.rs` persists *terminal presets only* today; extend it (or add `shed-app/src/prefs_store.rs`)
    and load these into the coordinator on startup — the coordinator's `rebuildPolicy`/grant logic reads
    them (AppModel:189-195), so without persistence a restart silently reverts policy.
- **`AuditStore` is best-effort (F9 ordering).** Mac's `append` swallows write errors (`try?`,
  AuditStore.swift) and is called **before** `respond` (AppModel:1300-1306). Preserve both: an I/O error
  (disk full) must **not** block the decision/`respond`; and if the Rust writer is offloaded (e.g.
  `spawn_blocking`), the entry must still be **enqueued before** the wire transmit so the "record before
  send" ordering holds.
- **Wire into `Backend`**: `Backend::from_config` gains an optional per-server minter (default `None`
  → GTK/tests unchanged; Tauri passes `Some(HostAgentTokenMinter)` for non-mock secure servers) — the
  single C2 change, since `Client`/`ControlTokenProvider`/401-retry already exist. **Construction order
  (panel):** Tauri today builds `Backend` before `setup` (lib.rs:214); Phase B must create the
  `HostAgentClient` **before** `Backend::from_config` (move backend construction into `setup`, or create
  the client earlier) so the minter can be threaded per server.

### 2.3 Platform → `tauri/src-tauri/` + `tauri/ui/`
- **IPC ops** (mirror `IPCHandlerImpl` op names exactly, so the harness is shared): `approvals.list`,
  `approval.decide`, `activity.list`, `activity.log_path`, `policy.set` (**test-mode-gated**, F8),
  `policy.list`, `notifications.list`, `notification.invoke`, `notification.open`, `ui.set_ssh_approval`.
  Registered in `ipc.rs::dispatch` (the `ipc.rs:124` match).
- **Coordinator wiring** in `lib.rs::setup`: construct `HostAgentClient` **before** `Backend::from_config`
  (so clients can mint), spawn the event loop + the 1s expiry tick, hold the coordinator in Tauri state.
  On `helloAck`, forward `gate_namespaces` to the frontend (a Tauri event) so the prefs pane shows an
  approval section **only** for delegated providers (mac: `prefs.gatedNamespaces = ack.gateNamespaces`,
  AppModel:1190). *(Test it — the fake advertises all three, so a port that ignores it wouldn't be caught.)*
- **`AuthGate` impl** (Linux) + **`Notifier` impl** — §3.
- **Frontend**: the Approvals pane (cards: op / shed / "expires in Ns" / Deny / Approve+gate), the
  Activity feed, the approval prefs (method / policy / TTL / per-shed). React + the linen theme; state
  fed by `invoke` + `listen` events (Phase-A `bridge.ts` pattern) — **no credentials in the webview**. The
  "expires in Ns" countdown is **display-only**: the frontend counts down from the `expires_at` on
  `PendingApprovalItem`; it never *decides* expiry (the backend's 1s tick does, F4), and the backend emits
  an approvals-refresh event when the tick changes the queue (or the pane re-polls `approvals.list`).

---

## 3. The Linux `AuthGate` — **DECIDED: polkit, behind a flexible trait**

On mac, `TouchID.authenticate` uses LocalAuthentication (`deviceOwnerAuthentication[WithBiometrics]`),
bypassed under test mode. Linux has no single equivalent, so the `AuthGate` **trait** is the seam and its
first impl is **polkit** — chosen (maintainer, 2026-07-03) as the widely-used, standard-desktop option and
deliberately kept **flexible** so fprintd/WebAuthn can slot in later behind the same trait.

**The three `ApprovalMethod`s (parity with mac's picker) map to Linux as:**

| `ApprovalMethod` (mac label) | mac | Linux (Phase B) |
|---|---|---|
| `prompt` — "Prompt (no Touch ID)" | approve is a **plain button press**, gate `none` | **same — a plain button press, no `AuthGate` at all** (works today; needs no polkit) |
| `biometrics-or-password` — "Touch ID or password" | Touch ID / Watch / password | **polkit** native-password dialog (the `AuthGate` impl) |
| `biometrics` — "Touch ID only" | Touch ID only | **fail-closed / unavailable** on Linux until fprintd (F5); shown but not selectable, or `Unavailable` if chosen |

Key consequence: because the `prompt`/`none`-gate method needs **no** `AuthGate`, a Linux user has a
**fully working, button-only approval flow through B0–B5** (and in any environment without polkit) — polkit
(B6) *adds* the password-gated method on top; it is never a gate on approvals working at all. Rejected: an
app-managed credential store (a second, weaker secret the app would hold — against "the app holds no
secrets"). PAM-via-setuid-helper was the runner-up but ships a setuid binary (more attack surface); polkit
keeps the password in the OS agent, never the app.

`AuthGate` outcomes remain the rich enum (F5): polkit-unavailable / no-agent / cancel / deny are all
distinct, audited, **deny-safe** (and leave the request *pending* per the mac-parity semantics in §2.2).
Under the hermetic harness the gate is bypassed (test-mode `Approved`), so the full approval matrix is
green independent of polkit — B6 wires the real dialog + a manual real-desktop smoke.

---

## 4. C1 — `shed-host-agent` on Linux **(RESOLVED — no prerequisite PR)**

Findings (from `../shed-extensions`, current `main` @ 0.4.9):
- **`token.get`/`token.response` minting is implemented on `main`** (`desktop_server.go:280` `handleTokenGet`;
  Linux socket resolution at `sockets.go:28`; wire matches Swift/Rust exactly). The published IPC *doc*
  table omits it (stale doc) — the code + its comments have it.
- **Linux build is viable by design**: TouchID is behind `//go:build darwin` with a `touchid_stub.go`
  (`//go:build !darwin`); pure-Go, no cgo blocker. Socket path resolves on Linux to
  `$XDG_RUNTIME_DIR/shed/host-agent.sock` (→ `~/.local/share/shed/…`), overridable via
  `$SHED_HOST_AGENT_SOCKET_DIR`.
- **The control-token-refresh fix is ALREADY MERGED** — `9a1ac77` (PR #41, *"re-mint control tokens on
  `token.get` instead of serving cache"*) is on `main`/`origin/main` @ 0.4.9; `forceTokenWithExpiry()` is
  live (`controltoken.go:51`). *(The `origin/fix/host-agent-control-token-refresh` branch, `c688e40`, is
  just the stale pre-squash source branch — superseded, safe to delete.)* So the staleness class C2 worries
  about — after a secure server restarts, the agent vending a stale cached token → the desktop's 401-retry
  gets the same stale token → wedge — is **already fixed agent-side**. No `shed-extensions` PR is a Phase-B
  prerequisite. (Landing the Rust token-expiry parse — §2.1 — correctly is still on *us*, and matters most
  precisely because this agent fix relies on the desktop re-minting.)

> **Only decision left (low-stakes; doesn't block the hermetic build): real-agent validation timing.**
> Validate the Rust `HostAgentClient` against the *real* `shed-host-agent` in a shed as a **late milestone
> (B7)**, or sooner? Recommend **hermetic-first** (fake agent through B6, then one real-agent pass) — the
> master plan already scopes A/B acceptance as hermetic.

---

## 5. Milestones (each independently green + committable + drivable)

Every commit: `make build && make test`; `make e2e-tauri` (mac) + `make tauri-build-linux` (WebKitGTK)
+ `make e2e-gtk` (GTK stays green — changes are additive). Per-milestone loop: implement → `/simplify`
(apply) → `/cursor:rescue` (adversarial; Codex rate-limited) → fold → gates → commit (trailers).

- **B0 — Pure core + `timefmt` + a CI leg.** `shed-core::approval` (models + codec + PolicyEngine) with
  ported unit tests (incl. malformed/missing-field decode) + the `shed-app::timefmt` flexible ISO-8601
  parse+format util with the **fail-closed** malformed-`expires_at` default (§2.1) + its `DateFormatting`
  case ports; **add the tauri CI job** (`make tauri-build-linux` + `make e2e-tauri`) so every later
  milestone is CI-gated (standing follow-up, pulled early). *Accept:* `cargo test -p shed-core` +
  `cargo test -p shed-app` (timefmt) green; **`cargo check -p shed-app` green on macOS** (the GTK dev loop
  compiles the new modules); CI runs the tauri leg; GTK/mac e2e untouched.
- **B0a — Extend `fake_host_agent.py`.** It is **not** reusable as-is: add `token.get` → `token.response`
  (success / error-reply / silent / drop modes, minting a deterministic `fake-tok-<n>`) and a
  `drop_connection()` that closes the live connection but keeps the listener up (so the client's
  backoff-reconnect is re-accepted) — needed for the C2 minter tests (B1) and the F3 disconnect test (B4).
  *Accept:* a smoke test drives each mode.
- **B1 — `HostAgentClient` + C2 minting** (`shed-app`). The UDS state machine + `HostAgentTokenMinter` +
  `Backend` minter wiring (`Some(minter)` per non-mock secure server) — with the **construction-order fix**
  (create the client before `Backend::from_config`; move backend build into `setup`). **Port *and extend*
  `HostAgentClientTests`** — the Swift suite covers success/error/timeout/disconnect/not-connected but
  **not** the single-resume/reconnect corners, so *add*: reply-after-timeout, duplicate-reply-after-success,
  disconnect-then-late-reply, stop-while-pending, unknown `in_reply_to`, reconnect-after-drop. *Accept:*
  `cargo test -p shed-app` (client matrix); the Rust client **handshakes with `fake_host_agent.py`** and
  correlates `token.get` (a focused integration test using B0a); the minter is fail-closed on error/empty
  (F6); GTK still passes `None` → unchanged.
- **B2 — The coordinator + `AuditStore` + `PrefsStore` + seam-trait defs** (`shed-app`), as the **two-phase
  mpsc actor** (§2.2), with a **blockable** test `AuthGate` + `FakeNotifier` + injectable `Clock`. Port the
  full `decide_approval` logic incl. the mac-parity gate-failure = stay-pending semantics. *Accept:* Rust
  unit tests for **all six edge-cases** (F3/F4/F7 + sticky-vs-TTL + reevaluate + expire-to-deny) **plus the
  deterministic post-gate TOCTOU test** (hold the gate open, advance the clock past `expires_at`, release
  `Approved`, assert the wire decision was the tick's `deny` — *not* a late approve, *and* no grant/rule
  persisted), the F12 `server:""`-stays-`""` persistence test, audit-before-transmit (F9), and valid-grants.
- **B3 — Tauri IPC ops + coordinator wiring + emit** (`tauri/src-tauri`). Register the 10 ops; start the
  client + expiry tick in `setup`; emit approvals/activity updates to the frontend; `FakeNotifier` under
  test mode. `policy.set` test-mode-gated (F8). *Accept:* the ops are drivable over the tauri IPC socket.
- **B4 — Harness: generalize to `--target tauri` + the full matrix.** Add an `_APPROVAL_TARGETS` /
  capability marker (replacing blanket `mac_only` on the approval suite), implement the TauriClient
  approval ops, add `SHED_TAURI_HOST_AGENT_SOCKET` + the fake-agent/policy-reset fixtures for tauri
  (flip the `mac`-only conditionals in `conftest.py`). *Accept:* **the full approval matrix (every `test_`
  in `test_approvals.py`, enumerated as a checklist) passes at `--target tauri`** (hermetic) + the three
  coverage adds (§6), and stays green at `--target mac`.
- **B5 — Frontend: Approvals pane + Activity feed + approval prefs.** The React panes + prefs, linen
  theme, fed by invoke/listen; the "expires in Ns" countdown; the fingerprint/gate affordance. *Accept:*
  the `notification.open → navigates to approvals` + pane-render assertions pass; WebKitGTK render gate
  green; screenshot eyeballed (Docker capture).
- **B6 — Linux `AuthGate` (polkit, §3) + `Notifier` (D-Bus).** The real polkit password dialog behind the
  `AuthGate` trait (flexible for fprintd/WebAuthn later) + native notifications, capability-detected,
  fail-closed. The `prompt`/no-gate button-only method already works from B2 (no gate); `biometrics`-only
  is `Unavailable` on Linux. *Accept:* gate returns the rich enum; polkit-unavailable → `Unavailable` →
  request stays pending → expire-to-deny (deny-safe); test-mode still bypasses; a manual real-desktop smoke.
- **B7 (gated on C1 decision) — real-agent validation** in a shed + (if chosen) the `shed-extensions`
  `c688e40` PR. *Accept:* the Rust client mints + gates against the *real* `shed-host-agent`; a real
  secure-server request approves end-to-end.

**Sequencing rationale:** the security *logic* (B0–B2) is proven by unit tests before any platform
surface; the hermetic *matrix* (B3–B4) is green before the real gate (B6) and before real credentials
(B7). The UI (B5) can precede or follow B4 since the matrix is IPC-driven; the Approvals/Activity pane
stubs already exist from Phase A.

---

## 6. The `decide_approval` edge-cases — REQUIRED tests (mapped to the shipped matrix)

These are the mac suite (**every `test_` in `tools/shedtest/test_approvals.py`** — enumerate the exact
list at B4 and treat "the full matrix passes" as an auditable checklist, so a silently-dropped test during
the port is caught; do not hardcode a count) that must pass at `--target tauri`, plus their `shed-app`
unit-test analogs. The mac anchors are the spec:

| Edge-case (invariant) | mac coordinator anchor | harness test |
|---|---|---|
| **Post-gate TOCTOU** — expired *while the prompt was up* (F4) | `AppModel:1243-1244` | **no harness test exists** (test-mode gate is instant) — **new `shed-app` unit test** via the *blockable* gate + injectable clock (§2.2/B2): hold gate → expire → release `Approved` → assert tick-`deny`, no late approve, no grant |
| Pre-gate expiry re-check (F4) | `AppModel:1228` | `test_expiry_fails_closed` (tick path) + a unit test for a decide on an already-expired request |
| Malformed `expires_at` fails closed (F4/§2.1) | `DateFormatting` → `.distantPast` | **new** — unparseable `expires_at` ⇒ treated as expired, no approve (fake emits a bad timestamp) |
| Deny supersedes a live session grant (F7) | `AppModel:1252` | `test_deny_evicts_live_session_grant` |
| Per-shed **sticky** vs per-session **TTL** | `AppModel:1263-1276` | `test_per_shed_sticky_grant`, `test_session_grant_auto_approves_next`, `test_time_based_allow_invalid_ttl_falls_back_to_default` |
| Fail-closed **drop all pending** on disconnect (F3) | `AppModel:1191-1198` | *(add a disconnect test at `--target tauri`; mac lacks one — a coverage add)* |
| **Re-evaluate** pending on policy change | `AppModel:213-224` | `test_ssh_policy_change_resolves_pending`, `test_ssh_pref_change_resets_session_grant` |
| **Expire-to-deny** after TTL (F4) | `AppModel:1286-1295` | `test_expiry_fails_closed` |
| Per-server shed isolation | `PolicyEngine` server match | `test_per_server_shed_isolation`, `test_server_field_propagates` |
| Persist per-shed allow/deny rule | `AppModel:1257-1261` | `test_always_allow_persists_per_shed_rule`, `test_always_deny_persists_per_shed_rule` |
| Auto approve/deny (no prompt) | `handleApprovalRequest` | `test_policy_auto_approve/deny`, `test_ssh_policy_always_allow/deny` |
| Notification post / invoke / open / suppressed-for-auto | `NotificationPresenter` seam | `test_notification_posted_and_invoked`, `_open_navigates`, `_not_posted_for_auto_policy` |
| Gate + defaults exposed on the pending item | `PendingApprovalItem` encode | `test_pending_item_exposes_gate_and_defaults` |
| Audit log path + event-stream all namespaces | `AuditStore` + `ingestEvent` | `test_audit_log_path_exposed`, `test_event_stream_covers_all_namespaces` |

**Coverage adds (the mac suite lacks these):**
1. *disconnect-drops-pending* (F3) — using the new `fake.drop_connection()` (B0a): drop the connection with
   a request pending; assert the queue empties and a late `approval.decide` is a no-op.
2. the *post-gate TOCTOU* unit test (above) — the single most security-relevant gap, since the mac suite's
   test-mode gate is instant and never opens the `AppModel:1243-1244` window.
3. *malformed `expires_at`* fails closed — the fake always emits a well-formed timestamp today.

---

## 7. Harness generalization (`--target tauri`)

- **Capability marker** (`_marks.py`): add `_APPROVAL_TARGETS = {"mac", "tauri"}` +
  `needs_approvals = skipif(target not in _APPROVAL_TARGETS)`; retag the approval suite from `mac_only`
  to `needs_approvals` (GTK stays skipped until its pane lands).
- **Fixtures** (`conftest.py`): flip `_reset_policy` and the `_app_session` host-agent branch from
  `if target == "mac"` / `!= "mac"` to `in _APPROVAL_TARGETS`, and rewrite `_reset_policy` to build its
  client via `ui.make_client(target)` (it hardcodes `ShedDesktop(...)` today) so it resets the *tauri*
  app's policy too. The session-scoped `fake` fixture is reused, but points at the **extended**
  `fake_host_agent.py` (B0a — `token.get` + `drop_connection`).
- **Launch env** (`ui.py`): the tauri subprocess launch gains
  `SHED_TAURI_HOST_AGENT_SOCKET=<fake.socket_path>` (mirrors mac's `SHED_DESKTOP_HOST_AGENT_SOCKET`).
- **`TauriClient`** (`client.py`): add `approvals_list`, `approval_decide`, `policy_set`, `policy_list`,
  `activity_list`, `activity_log_path`, `notifications_list`, `notification_invoke`,
  `notification_open`, `set_ssh_approval` (thin IPC wrappers, op names identical to mac).
- **`Paths`/socket resolution** in `shed-app`: `host_agent_socket()` honors `SHED_TAURI_HOST_AGENT_SOCKET`
  (test) else the canonical `$SHED_HOST_AGENT_SOCKET_DIR`→`$XDG_RUNTIME_DIR/shed`→`~/.local/share/shed`
  chain (shared with a future GTK pane). `state_dir()` for `audit.jsonl` honors the test override.

---

## 8. Acceptance (phase-level)
- `cargo test -p shed-core` (approval models + codec + PolicyEngine) and `cargo test -p shed-app`
  (client + coordinator + gate + audit) green.
- The Rust `HostAgentClient` **handshakes with `fake_host_agent.py`** and correlates `token.get`.
- The **full approval matrix** (not one happy path) passes at `--target tauri`, hermetic, **including** the
  new post-gate-TOCTOU, disconnect-drops-pending, and malformed-`expires_at` coverage adds (§6).
- C2: a stale/failed mint sends **no** token (F6), demonstrated in a test.
- **F1 assertion:** an explicit test that no op result (`approvals.list`/`activity.list`/…) carries a
  token, key, or auth-factor field.
- `make e2e-gtk` and `make e2e-tauri`/`make tauri-build-linux` green; the tauri CI leg runs them.
- (B7, if run) real-agent validation in a shed.

---

## 9. Decisions (settled) + deferrals (log)
- **§3 AuthGate — DECIDED (2026-07-03):** **polkit**, behind a flexible `AuthGate` trait (fprintd/WebAuthn
  later). The `prompt`/no-gate **button-only** method is a first-class Linux option needing no gate; the
  `biometrics`-only method is fail-closed on Linux until fprintd.
- **F13 — DECIDED (2026-07-03):** trust the webview for the user's *own* preference changes (CSP blocks
  remote content + in-process trust); keep `policy.set` test-mode-gated and the drivability socket
  owner-only. (Stronger "gate weakening behind AuthGate" left as a future option.)
- **§4 C1 — resolved:** the agent-side token-refresh fix is already merged (`9a1ac77`/PR #41); only
  real-agent validation *timing* remains (B7, hermetic-first).
- **Deferred:** Linux biometrics (fprintd/WebAuthn); the GTK approval pane (roadmap M6); AWS/Docker
  *gating* (audit-only today); a mint circuit-breaker (§1.4). Log any milestone deferrals in the commit + here.

---

## The working flow (unchanged from Phase A — keep doing this)

0. **Branch** `tauri-phase-b` off `feat/rust-core` (stacked); one PR for the phase (or per sub-phase).
1. **Plan + threat model → panel** (this doc). `/planning:ask-panel plans/tauri-phase-b.md`
   (Codex + Kimi K2.6 + CodeRabbit); fold findings **before** code. Security-critical ⇒ mandatory.
2. **Execute milestone-by-milestone.** Each: implement → `/simplify` (apply) → `/cursor:rescue`
   (primary; `/codex:codex-rescue` only if Cursor's down) → fold → gates → commit.
3. **Green every commit.** `make build && make test`; `make e2e-tauri` + `make tauri-build-linux` +
   `make e2e-gtk`. Drive + assert every new op over IPC; eyeball new UI via the Docker screenshot.
4. **Commit trailers (required):** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
   and a `Claude-Session:` line. Log deferrals.
5. **Ship the PR** onto `feat/rust-core`, then `/git-commands:watch-pr <n>` → green → merge.
