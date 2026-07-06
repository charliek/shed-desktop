# Tauri Agents / Remote-Control (B2) — hands-on test plan

*Phase C, B2 (the Agents/RC pane) — what landed, and what to exercise by hand on
macOS + Linux. Automated coverage is green (`test_agents.py` at `--target tauri`
+ `--target mac`; the render gate on Linux); this plan covers the **real SSH
path** and the visual/UX bits the hermetic harness can't drive.*

## What B2 delivered

The Tauri client's **Agents** pane is now live (was a `SEED_AGENTS` stub), on the
shared Rust base:

- **`shed-core::rc`** (pure): the pane classifier, prompt normalization, the
  `shed-ext-rc` argv + non-interactive SSH argv, the wire DTOs + `RcSession`.
- **`shed-app::rc`** (feature `rc`): `RcService` over the `RcRunner` **portability
  seam** (desktop = `ssh` subprocess; the seam is where a future mobile in-process
  runner plugs in) + the in-memory session store.
- **Tauri**: `rc.classify/list/launch/kill/inject_test` + `agents.dump` IPC ops,
  `rc_list/rc_launch/rc_kill` invoke commands, and the React pane (live table +
  launch form + console/open-URL/kill).

## Feature status (per platform)

| Capability | macOS (Tauri) | Linux (Tauri) | Notes |
|---|---|---|---|
| Classify pane → state/url | ✓ hermetic | ✓ hermetic | pure, unit + e2e tested |
| Launch (test mode / synth) | ✓ | ✓ | `test_agents` green both targets |
| Launch (real SSH `shed-ext-rc`) | ⏳ hands-on | ⏳ hands-on | needs a running shed + `shed-ext-rc` in the image |
| List (fan-out probe) | ⏳ hands-on | ⏳ hands-on | real path exercised by the hands-on run |
| Console (tmux attach) | ⏳ hands-on | ⏳ hands-on | opens the chosen terminal |
| Open-in-Claude (session URL) | ⏳ hands-on | ⏳ hands-on | opens claude.ai/code/session_… |
| Kill | ✓ hermetic · ⏳ real | ✓ hermetic · ⏳ real | idempotent guest-side |
| `agents.dump` drivability | ✓ | ✓ | logical render truth (headless-friendly) |

## Hands-on: the real SSH path (both platforms)

Prereq: a **running shed** with `shed-ext-rc` on PATH (the shed `full` image), and
SSH reachability (`~/.shed/known_hosts` pinned). For a dev binary, `scp` it and set
`SHED_EXT_RC_BIN=/tmp/shed-ext-rc`.

1. **Build + run the Tauri app** for the platform:
   - macOS: `cd tauri && <the Tauri dev/bundle run>` (WKWebView).
   - Linux: `make tauri-run` equivalent / the `.deb` (WebKitGTK).
2. **Open Agents** → **New session**. Pick a running shed, kind **Claude**, add an
   initial prompt ("summarize this repo"), **Launch**. Expect: the SSH shell-out
   runs `shed-ext-rc create --wait` (~20s), the row appears **ready** with a
   `claude.ai/code/session_…` URL.
3. **Open in Claude** → the session opens in the browser; drive the agent remotely.
4. **Console** → opens your terminal attached to `rc-<slug>` (`tmux attach`).
5. **Launch a `shell`** with an initial command → verify it runs.
6. **Kill** a session → the row disappears; a second kill is a no-op (idempotent).
7. **Classify states**: for a fresh claude-rc, watch **starting → ready**; for an
   untrusted workspace, **needs-trust**; not-logged-in → **needs-auth**.

## NOT covered here — the credential-gate real-agent smoke (B7 / A5)

*Deliberately left for the maintainer — it needs a running `shed-host-agent`
(holds real keys; the agent must NOT start it), a configured secure server, and
biometrics. Runbook: `plans/tauri-phase-b.md` §1 pass bar.* In short: client shows
**connected** → mint a control token via `token.get` → an SSH sign routes an
approval → the Touch-ID (macOS, B3, not yet built) / polkit (Linux) gate approves
end-to-end → a cancel expires-to-deny → killing the agent mid-pending drops the
queue (F3).

## Remaining in Phase C (not B2)

- **B3** — macOS Touch-ID `AuthGate` (objc2). Until then the mac gate is
  `Unavailable`; use the button-only "prompt" method for the mac approval smoke.
- **B1b** — the mac popover (Swift-vs-Tauri decision), **B4** — prefs + autostart,
  **A4** — D-Bus notification withdraw (Linux).
- **A5 = B7** — the real-agent smoke above, on a signed build (the flip gate).
