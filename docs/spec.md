# shed-desktop — Project Specification

Status: draft v0.1 (kickoff)
Owner: Charlie Knudsen
Audience: engineering team + Claude Code
Repo (new): `charliek/shed-desktop`

This document specifies a native macOS desktop application that ties together the
existing shed toolchain — [`charliek/shed`](https://github.com/charliek/shed),
[`charliek/shed-extensions`](https://github.com/charliek/shed-extensions), and
[`charliek/shed-remote-agent`](https://github.com/charliek/shed-remote-agent) — into a
single menu-bar-resident control surface. It is written to be actionable by an
engineering team and by Claude Code. Sections marked `DISCOVERY` are deliberately
unresolved and should be answered by a spike before the relevant milestone.

---

## 1. Goals and non-goals

### Goals

- Give a developer one resident Mac app that can: list and create sheds, launch
  agent / remote-control sessions in them, approve credential requests from the
  shed-extensions host agent, and surface a live event feed of what is happening.
- Make the credential-approval experience first-class: route host-agent approval
  prompts into the app, let the user configure approval policy per namespace and per
  shed, and keep a richer audit trail than the file-based log that exists today.
- Be a compelling internal demo: trivial for an engineer at the company to install,
  launch an agent inside an isolated VM, and watch it work — lowering the barrier to
  running agents in a sandbox rather than on a laptop directly.
- Stay small, launch instantly, and feel native (menu bar, Touch ID, notifications,
  launch-at-login).

### Non-goals (v1)

- Not a replacement for `shed-remote-agent`. That project is a mobile-first
  proof-of-concept web UI; this app does not depend on or wrap its Bun backend. We
  reuse its *logic and conventions* (SSH + tmux RC bootstrap, SSE parsing, RC state
  classification) as reference, not its runtime.
- Not an embedded terminal emulator. Opening a shell into a shed delegates to the
  user's terminal app. An in-app console is explicitly deferred (see §11).
- Not cross-platform. macOS only. (A future GTK/Linux sibling is out of scope but the
  core/UI split below keeps the option open.)
- No multi-user / team features, no remote hosting of the app itself.

---

## 2. Technology selection

### Decision: Swift native (SwiftUI + AppKit)

Rationale, given the constraints that drove it:

- The app's entire capability surface is: call HTTP endpoints, consume SSE streams,
  shell out and read stdout/pipes, and integrate deeply with macOS (menu bar, Touch
  ID, notifications, login item). Swift handles the first three natively
  (`URLSession.bytes`, `Process`/`Subprocess` + `Pipe`) and is categorically the best
  at the fourth.
- The one capability that would have favored a web stack — an embedded streaming
  terminal — is explicitly a non-goal. Terminals are delegated to the user's terminal
  app, removing SwiftUI's weakest area from the critical path.
- Smallest binary, instant launch, obviously-native feel — all of which matter for the
  internal demo.

Rejected alternatives:

- Electron — bundles Chromium; ~85–120 MB. Fails the size bar.
- Tauri — viable and was the earlier lean *when an embedded terminal was assumed*. With
  terminals delegated out, its advantage (web-native streaming UI) no longer applies,
  and its weak spots (menu-bar popover, Touch ID via FFI) are exactly this app's
  headline features.

### Constraints and escape hatches

- Minimum target: macOS 13 Ventura (required for SwiftUI `MenuBarExtra`).
- Architecture: Apple Silicon (arm64) is the only first-class target, consistent with
  shed's own VZ backend requirement.
- Web escape hatch: if a future view genuinely needs web rendering (e.g. a rendered
  markdown research brief, or — if §11 is ever revisited — an xterm.js console), embed
  a `WKWebView` inside an `NSViewRepresentable` scoped to that one pane. Not the
  default substrate.

### Suggested project layout

```
shed-desktop/
  Package.swift                 # SPM; app is an executable target
  Sources/
    ShedDesktopApp/             # @main, MenuBarExtra, WindowGroup, app lifecycle
    ShedKit/                    # core, no UI — the "core" half of a core/UI split
      ShedServerClient.swift    # HTTP client for shed-server API
      SSEClient.swift           # generic SSE line parser over URLSession.bytes
      HostAgentClient.swift     # talks to shed-host-agent (CLI and/or socket)
      RemoteControl.swift       # RC bootstrap + state classifier (ported logic)
      TerminalLauncher.swift    # builds + launches terminal commands
      AuditStore.swift          # local audit log (append + query)
      Models.swift              # Shed, Host, RcSession, ApprovalRequest, AuditEntry
    ShedDesktopUI/              # SwiftUI views, view models
  Tests/
    ShedKitTests/               # classifier, SSE parser, policy engine unit tests
```

The `ShedKit` / UI split is deliberate: it keeps all I/O and logic testable without a
running UI, and is the seam a future Linux port would cut along.

---

## 3. System context

The app is a coordinator. It does not run sheds or hold credentials; it observes and
drives components that already exist on the developer's Mac and on shed hosts.

```
  +-------------------------------------------------------------+
  |  macOS desktop (developer's Mac)                            |
  |                                                             |
  |   +-------------------+        +------------------------+   |
  |   |  shed-desktop     |        |  shed-host-agent       |   |
  |   |  (this app)       |<------>|  (shed-extensions)     |   |
  |   |                   | approve| SSH keys, AWS STS,     |   |
  |   |  - menu bar       | /deny  | docker creds, Touch ID |   |
  |   |  - dashboard      |        +-----------+------------+   |
  |   |  - approval queue |                    | SSE          |
  |   |  - agent launcher |        +-----------v------------+   |
  |   |  - audit          |        |  shed-server (local)   |   |
  |   +----+----------+---+        |  HTTP :8080            |   |
  |        |          |            +-----------+------------+   |
  |        | HTTP     | SSH/terminal           | vsock          |
  +--------|----------|------------------------|----------------+
           |          |                        |
           v          v                        v
   shed-server   Terminal.app /          shed VM(s) (guest)
   (remote hosts) iTerm / Ghostty        shed-agent, shed-ext-*
   over Tailscale  -> ssh + tmux attach
```

Key relationships:

- shed lifecycle + events: HTTP to one or more `shed-server` instances (local and
  Tailscale-reachable), discovered from `~/.shed/config.yaml`.
- credentials/approvals: a channel to `shed-host-agent`. The host agent already brokers
  ssh-agent, aws-credentials, docker-credentials and already has a Touch ID gate; this
  app adds a new gate mode that delegates the decision to the app (§7).
- terminals + RC: SSH into a shed (as `<shed>@<host>:<sshPort>`) and drive `tmux`,
  mirroring `shed-remote-agent`'s approach, but launching the user's terminal app for
  interactive attach instead of bridging a PTY over WebSocket.

---

## 4. Source-of-truth: what the existing APIs give us

This section pins down the real, documented surfaces the app builds on, so
implementers don't have to re-derive them.

### 4.1 shed-server HTTP API (port 8080, no auth, network-gated)

Relevant endpoints (full reference: shed docs → Reference → HTTP API):

- `GET /api/info` — server name, version, backend (`vz`/`firecracker`).
- `GET /api/sheds` — list; each shed has `name`, `status`
  (`running|stopped|starting|error`), `created_at`, `repo`, `backend`, `ip_address`,
  `cpus`, `memory_mb`.
- `POST /api/sheds` — create. Body: `name` (req), `repo`, `image`, `backend`,
  `local_dir`, `cpus`, `memory_mb`, `from_snapshot`, `upper_size_bytes`,
  `no_provision`. `repo` and `local_dir` are mutually exclusive.
  - Set `Accept: text/event-stream` to stream creation progress as SSE:
    `event: progress` (`{message}`), `event: complete` (final shed object),
    `event: error` (`{code,message}`).
- `GET /api/sheds/{name}`, `DELETE /api/sheds/{name}`.
- `POST /api/sheds/{name}/start|stop|reset`.
- `GET /api/sheds/{name}/sessions`, `GET /api/sessions` — tmux sessions (name,
  shed_name, created_at, attached, window_count).
- `DELETE /api/sheds/{name}/sessions/{session}` — kill a tmux session.
- `GET /api/images`, `/api/images/inspect/{name}`, `POST /api/images/pull|tag`, etc.
- `GET /api/system/df`, `POST /api/system/prune` — disk usage + cleanup.
- `GET /api/sheds/{name}/connect/{port}` — raw TCP tunnel via HTTP upgrade
  (`Upgrade: shed-tcp`). Foundation for port-forwarding; not required for v1 terminal
  flow but useful later.

### 4.2 shed extension message bus (host-side listener API)

The plugin bus is how guest processes reach host listeners. Endpoints on shed-server:

- `GET /api/plugins/listeners` — active listeners.
- `GET /api/plugins/listeners/{namespace}/messages` — SSE subscribe (one listener per
  namespace; `system:*` reserved).
- `POST /api/plugins/listeners/{namespace}/respond` — respond to a message (envelope
  must include `shed.name`).
- `GET /api/plugins/sheds` — sheds with active message channels.

Message envelope fields: `id` (UUIDv7), `namespace`, `type`
(`request|response|event`), `in_reply_to`, `final`, `timestamp`, `payload`, `shed`
(`{name, backend, server}`).

Important: today, `shed-host-agent` *is* the listener for the credential namespaces
(`ssh-agent`, `aws-credentials`, `docker-credentials`). The app should NOT try to
register as a competing listener on those namespaces — only one listener per namespace
is allowed, and stealing it would break credential brokering. The app interacts with
approvals *through the host agent* (§7), not by subscribing to the bus directly. The
bus listener API is documented here for completeness and for possible future
app-owned namespaces (e.g. a `monitor` namespace for activity events).

### 4.3 shed-extensions host agent (today's behavior)

- `shed-host-agent` runs on the Mac, subscribes to credential namespaces via SSE,
  fulfills sign/credential requests using host keys / AWS / docker helpers.
- Existing approval modes (config `approval:`): `biometrics`,
  `biometrics-or-password`, `none`. Touch ID is evaluated on-device via
  LocalAuthentication.
- Audit log: JSON lines at `~/.local/share/shed/extensions-audit.log`. Fields: `ts`,
  `shed`, `ns`, `op`, `result` (`ok|denied|error`), `detail`, `approval`.
- In-VM health: `shed-ext status` reports per-namespace connectivity.

### 4.4 shed-remote-agent (reference only — do not depend on its backend)

We mine this for proven patterns:

- RC session = a detached `tmux` session named `rc-<slug>` on a target.
- Three kinds: `agent` (`claude remote-control …`), `repl` (`claude … /rc`), `shell`
  (`bash -l`). Default `repl`.
- Bootstrap: `tmux new-session -d -s rc-<slug> -c <workdir> -e SRA_*=… '<inner cmd>'`.
- State probing: `tmux capture-pane -p -S -200` + a pure classifier producing
  `starting | ready | reconnecting | needs-trust | needs-auth | dead`.
- Slug alphabet is confusable-free (`abcdefghjkmnpqrstuvwxyz23456789`).
- The classifier regexes (URL detection, needs-trust, needs-auth, reconnecting, ready)
  are the part most worth porting verbatim; they are unit-tested upstream in
  `apps/api/src/lib/__tests__/rc.test.ts`.

The interactive-attach mechanism differs: upstream bridges tmux PTY to xterm.js over a
WebSocket. We instead launch the user's terminal app with an `ssh -t … tmux attach`
command (§6).

---

## 5. Connectivity strategy

How the app reaches sheds is split into resolved decisions and discovery spikes.

### 5.1 Resolved

- Host discovery: parse `~/.shed/config.yaml` for the list of shed servers (name,
  host, httpPort, sshPort), the same source `shed-remote-agent` uses. Watch the file
  for changes.
- Multi-host: the app talks to each configured `shed-server` directly over HTTP. There
  is no central backend; fan-out happens in-app. Unreachable hosts are surfaced as a
  degraded state, never a hard failure of the whole list.
- Terminal/RC dispatch: SSH into the shed using the credentials shed-server publishes
  (`<shed>@<host>:<sshPort>`), exactly as remote-agent does.

### 5.2 `DISCOVERY-1` — shed CLI vs shed-server HTTP

Decide whether shed lifecycle operations go through the `shed` CLI (shelling out) or
the shed-server HTTP API directly.

- Recommendation to validate: HTTP as the primary path (typed responses, native SSE
  progress streaming, no parsing of human-formatted CLI output, works uniformly for
  remote hosts), with the `shed` CLI as a fallback for anything the HTTP API does not
  expose or for environments where only the CLI is configured.
- Spike output: a short table of every operation the app needs (list, create+progress,
  start, stop, reset, delete, sessions, images) mapped to HTTP endpoint vs CLL command,
  flagging any gap where the CLI can do something the HTTP API cannot (or vice versa).
- Watch items: the HTTP API has no authentication and relies on network-level access
  control (Tailscale/firewall). The app must never expose it further and must treat a
  reachable shed-server as already-trusted by the network, not by the app.

### 5.3 `DISCOVERY-2` — host-agent event/approval channel

This is the most important spike because it requires a change to `shed-extensions`,
not just to this repo. See §7 for the functional requirement. The spike must choose a
transport and define the wire protocol.

Candidate transports (evaluate, pick one, document why):

1. New host-agent CLI subcommand(s):
   - `shed-host-agent events --follow` — emit a unified JSON-lines stream of audit
     entries and lifecycle/approval events to stdout (the app reads the pipe). This is
     the lowest-friction option and matches the user's stated instinct.
   - `shed-host-agent approvals --serve` (or similar) — a request/response channel for
     the delegated-gate decision (§7), since a one-way `--follow` stream cannot carry
     the approve/deny reply.
2. A local Unix domain socket exposed by the host agent that the app connects to for
   both the event stream and the approval request/response. More robust than pipes for
   bidirectional, multi-consumer use; more work in the host agent.
3. A small loopback HTTP+SSE endpoint on the host agent (e.g. `127.0.0.1`), mirroring
   the shapes shed-server already uses. Most consistent with existing patterns; adds a
   listening socket to a security-sensitive process (justify carefully).

Decision criteria: bidirectional (must carry approve/deny back), survives app restart,
single source of truth for the audit stream, minimal new attack surface on a process
that holds credentials, and minimal new code in shed-extensions.

Deliverable of the spike: a written mini-RFC against `charliek/shed-extensions`
proposing the new command/socket and its message schema, plus a stub implementation
behind a feature flag so this app can be developed against it.

---

## 6. Functional requirements

### FR-1 Menu bar presence (pillar: always-on)

- Resident `MenuBarExtra` with a status icon reflecting aggregate state: idle, sheds
  running (count), pending approvals (count, attention color).
- Dropdown shows: pending approvals (inline approve/deny), running sheds (with a
  one-click terminal action), ready agents, and quick actions (new shed, open
  dashboard, preferences, quit).
- Launch-at-login via `SMAppService` (user-toggleable in preferences).
- The app has no Dock presence by default (menu-bar / accessory activation policy),
  with an option to show the main window.

### FR-2 Shed dashboard (pillar: lifecycle)

- List all sheds across all configured hosts, grouped or filterable by host, with
  status (running/stopped/starting/error), image variant, backend, resource sizing,
  uptime, and which credential namespaces are currently active for that shed (from
  host-agent state / `shed-ext status` where available).
- Live updates: reflect status changes without manual refresh (poll `GET /api/sheds`
  on an interval and/or react to the host-agent event stream from DISCOVERY-2).
- Per-shed actions: start, stop, reset (with confirm), delete (with confirm), open
  terminal, launch agent, view sessions.

### FR-3 Create shed (pillar: lifecycle)

- A create flow mirroring remote-agent's: pick host, name, source (git repo via a
  `gh`-backed picker OR a host-side local directory — mutually exclusive), image
  variant, backend, CPU/memory, provision toggle.
- Stream creation progress live using the shed-server SSE create stream
  (`Accept: text/event-stream`), showing each `progress` message and surfacing
  `error` events inline.
- Repo picker: `DISCOVERY-3` — reuse remote-agent's `gh repo list` approach (shell out
  to `gh`, cache briefly) vs. a simpler free-text `owner/repo` entry for v1. Recommend
  free-text first, `gh` picker as a fast follow.

### FR-4 Credential approval queue (pillar: auth — headline feature)

- When the host agent's approval mode is `shed-desktop` (§7), incoming credential
  requests appear as an approval queue in both the dashboard and the menu bar.
- Each request shows: namespace (`ssh-agent`/`aws-credentials`/`docker-credentials`),
  operation (`sign`/`get_credentials`/…), originating shed, and human-readable detail
  (key type, role ARN, registry).
- Actions: Approve (optionally gated by the app's own Touch ID via `LAContext`), Deny,
  and policy shortcuts ("always allow ssh for this shed", "open policy…").
- A request has a bounded lifetime; the UI shows a countdown and the request expires
  to a safe default (deny) if not actioned, consistent with the host agent's existing
  30s request timeout semantics. Exact timeout is negotiated in DISCOVERY-2.
- Every decision is recorded to the app's audit store (§FR-6).

### FR-5 Agent / remote-control launcher (pillar: agents)

- Launch an RC session in a running shed: choose shed, slug (auto-generated,
  confusable-free), display name, workdir (`/workspace` default), and kind
  (`agent`/`repl`/`shell`, default `repl`).
- Bootstrap via SSH + tmux using the documented command shape; classify pane state
  with the ported classifier into `starting|ready|reconnecting|needs-trust|needs-auth|dead`.
- For `agent`/`repl`, once `ready`, surface the `claude.ai/code…` URL with a one-click
  "Open in Claude" (`openLink`/`NSWorkspace`).
- List existing RC sessions per shed (filter tmux sessions by `rc-` prefix; recover
  metadata from the `SRA_*` tmux env vars), with state and a kill action.
- "Fix" affordances for `needs-trust` / `needs-auth` that explain the one-time manual
  step (attach, trust folder / `claude auth login`, recreate).

### FR-6 Activity + audit (pillar: auth/observability)

- A merged, chronological event feed combining: host-agent audit entries (credential
  ops), shed lifecycle transitions, and RC state changes.
- The app maintains its own audit store (append-only, locally queryable) that is a
  superset of the host-agent's JSON log — it adds the app's own approval decisions,
  policy that was applied, and RC/lifecycle events.
- Export / reveal-in-Finder of the audit log. Format: JSON lines, schema a superset of
  the existing `extensions-audit.log` fields (`ts, shed, ns, op, result, detail,
  approval`) plus `source`, `policy`, and a stable `id`.

### FR-7 Terminal integration (pillar: agents/lifecycle)

- "Open terminal" for a shed launches the user's preferred terminal app and runs the
  SSH command that drops them into the shed (and optionally attaches to a chosen tmux
  session).
- `DISCOVERY-4` — terminal launch mechanism. Options: `open -a <Terminal>` with a
  command, AppleScript/`osascript` for Terminal.app and iTerm, or a user-configurable
  command template (most flexible; recommended) such as
  `ghostty -e "ssh -t <shed>@<host> -p <sshPort> tmux attach -t <session>"`. Detect
  installed terminals; let the user pick the default in preferences.

### FR-8 Preferences

- Approval policy (default mode + per-namespace + per-shed rules) — see §7.3.
- Default terminal app / command template.
- Launch at login, show/hide Dock icon, notification preferences.
- Host management view (read-only reflection of `~/.shed/config.yaml`, with a hint to
  edit the file; the app does not modify shed config in v1).

---

## 7. The `shed-desktop` approval gate (cross-repo feature)

This is the defining feature and the one piece that requires coordinated change in
`shed-extensions`. It is called out separately because it is a contract between two
repos.

### 7.1 Today

`shed-host-agent` decides approvals itself. When `approval` is `biometrics` or
`biometrics-or-password`, it prompts Touch ID inline on the host before fulfilling a
sign/credential request. `none` disables the gate. The app cannot currently influence
or even observe these decisions except by tailing the audit file after the fact.

### 7.2 Proposed: a new `shed-desktop` approval mode

Add a new value to the host agent's `approval` config: `shed-desktop`. When set, for a
gated operation the host agent does not prompt locally; instead it emits an approval
request to a connected shed-desktop app and blocks on the reply (within its existing
request-timeout budget). The app renders the request (FR-4), the user decides
(optionally via the app's own Touch ID), and the decision returns to the host agent,
which then fulfills or rejects the credential operation.

Benefits this unlocks (and the reason to do it in the app rather than the host agent):

- User-configurable policy (per namespace, per shed, session-scoped trust) lives in a
  place with a real UI, instead of static host-agent config.
- Richer, centralized audit with the policy that was applied and the decision source.
- A single approval surface (menu bar + notifications) across all sheds and namespaces.

Safety properties to preserve:

- Fail-closed: if no app is connected, or the request times out, the host agent must
  deny (never silently approve). The new mode must degrade safely to the same outcome
  as an unanswered prompt today.
- No new credential exposure: the app never sees key material or secrets — only request
  metadata (namespace, op, shed, detail). The host agent remains the sole holder of
  credentials, exactly as in the current threat model.
- Single-consumer clarity: define behavior when zero or more than one app instance is
  connected. Recommend exactly-one, last-writer-wins registration, with fail-closed if
  none.

### 7.3 Policy engine (app side)

A pure, unit-testable component in `ShedKit` that, given an approval request and the
user's configured rules, returns one of `approve | deny | prompt`.

- Granularity: default mode, per-namespace override, per-shed override, and
  session-scoped grants ("approve for this session"). Most specific rule wins.
- `prompt` results route to the approval queue and (optionally) a Touch ID challenge.
- `auto-approve` rules should be constrained (e.g. docker-credentials limited to the
  host agent's registry allowlist) and must still be audited.
- All inputs and outputs are data structures; no I/O in the engine itself, so the whole
  policy matrix can be tested without a host agent.

### 7.4 Spike + RFC

DISCOVERY-2 (§5.3) is the transport; this section is the semantics. The combined
deliverable is a mini-RFC in `shed-extensions` plus a feature-flagged stub so the app
team is unblocked. Until the stub exists, the app implements the gate against a
local fake host-agent that replays recorded requests.

---

## 8. Data model (app-side, indicative)

```
Host         { name, host, httpPort, sshPort, reachable, backend, version }
Shed         { host, name, status, image, backend, repo|localDir, cpus,
               memoryMB, ipAddress, createdAt, activeNamespaces[] }
RcSession    { host, shed|machine, slug, tmuxSession, displayName, workdir,
               kind, state, url? }
ApprovalRequest { id, ts, namespace, op, shed, detail, expiresAt,
                  decision?, decidedBy?, policyApplied? }
PolicyRule   { scope(default|namespace|shed|session), namespace?, shed?,
               action(approve|deny|prompt|auto), gate(touchid|none) }
AuditEntry   { id, ts, source(host-agent|app|lifecycle|rc), shed?, ns?, op?,
               result, detail?, approval?, policy? }
```

These map directly onto the existing wire shapes (shed-server shed objects,
host-agent audit JSON, remote-agent RC bootstrap response) so adapters are thin.

---

## 9. Security model

- The app holds no credentials and no secrets. It coordinates processes that do.
- It honors the existing trust boundary: a reachable `shed-server` is trusted because
  the network (Tailscale/firewall) already trusts it. The app adds no remote attack
  surface of its own and must not expose any shed-server further.
- The approval gate is fail-closed (§7.2). A missing or unresponsive app results in
  denial, matching today's unanswered-prompt outcome.
- The app's own Touch ID gate uses LocalAuthentication on-device; no biometric data
  leaves the machine (same property the host agent has today).
- Audit is append-only and local; export is explicit, user-initiated.
- The app must not weaken any shed-extensions guarantee: SSH private keys and AWS
  long-lived credentials still never enter a VM; the app only ever handles request
  metadata.

---

## 10. Milestones

Each milestone is independently demoable.

- M0 — Skeleton + read-only dashboard.
  ShedKit `ShedServerClient` + `SSEClient`; parse `~/.shed/config.yaml`; list sheds
  across hosts; `MenuBarExtra` with running count; main window with the shed list.
  No mutations yet. Resolves DISCOVERY-1 (the spike lands here).

- M1 — Lifecycle + terminal.
  Start/stop/reset/delete; create-shed flow with live SSE progress; open-terminal via
  the chosen launch mechanism. Resolves DISCOVERY-4. Free-text repo entry (defer `gh`).

- M2 — Agent launcher.
  Port the RC classifier (with its unit tests); bootstrap RC sessions over SSH+tmux;
  list/kill RC sessions; "open in Claude" for ready agent/repl sessions; needs-trust /
  needs-auth guidance.

- M3 — Approval gate (the headline).
  Land the shed-extensions RFC + stub (DISCOVERY-2 / §7); approval queue in dashboard
  and menu bar; policy engine + preferences; app-side Touch ID; merged audit feed and
  audit store. This is the milestone that justifies the whole project; everything
  before it is also useful on its own, which de-risks the schedule.

- M4 — Polish + demo hardening.
  Notifications with actionable approve/deny; launch-at-login; degraded-state UX for
  unreachable hosts / stopped host agent; packaging, code-signing, and a one-command
  install for internal demo distribution.

---

## 11. Deferred / future (explicitly out of v1)

- Embedded terminal / in-app console (xterm.js in a `WKWebView`, or SwiftTerm).
  Revisit only if delegating to the terminal app proves insufficient.
- App-owned bus namespaces (e.g. a `monitor` namespace) for richer in-VM activity
  events surfaced in the activity feed.
- Port-forwarding UI on top of `GET /api/sheds/{name}/connect/{port}`.
- Snapshot management UI (the HTTP API already supports it).
- Writing to `~/.shed/config.yaml` / managing hosts from within the app.
- Linux/GTK sibling app reusing `ShedKit`-equivalent core.
- Worktree-mode `claude remote-control` (deferred upstream in remote-agent too).

---

## 12. Open questions (consolidated)

- DISCOVERY-1: shed CLI vs HTTP for lifecycle ops (recommend HTTP-primary). [M0]
- DISCOVERY-2: host-agent event + approval transport and wire protocol; requires a
  shed-extensions RFC. [M3, but spike early]
- DISCOVERY-3: repo picker — `gh`-backed vs free-text for v1 (recommend free-text
  first). [M1]
- DISCOVERY-4: terminal launch mechanism + terminal detection (recommend configurable
  command template). [M1]
- Approval request timeout budget and exact fail-closed semantics negotiated with the
  host agent. [M3]
- Behavior with multiple shed-desktop instances connected to one host agent
  (recommend exactly-one, fail-closed). [M3]

---

## Appendix A — reference links

- shed: https://github.com/charliek/shed · docs https://charliek.github.io/shed/
  (HTTP API and Extensions reference are the key pages)
- shed-extensions: https://github.com/charliek/shed-extensions ·
  docs https://charliek.github.io/shed-extensions/ (Status CLI + Security Posture)
- shed-remote-agent: https://github.com/charliek/shed-remote-agent ·
  docs https://charliek.github.io/shed-remote-agent/ (HTTP API + Remote Control are the
  pages to port logic from; the RC classifier lives in `apps/api/src/lib/rc.ts`)
