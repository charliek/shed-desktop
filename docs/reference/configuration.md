# Configuration

There are three places configuration lives, with deliberately little overlap:

1. **The Preferences window** — the handful of user-facing settings, persisted to
   `UserDefaults`.
2. **`~/.shed/config.yaml`** — the host list, owned by the `shed` CLI and read **read-only**
   by the app.
3. **Environment variables** — overrides for testing, packaging, and release. Not something
   a normal user sets.

The app intentionally exposes a *small* settings surface; most behavior is derived from the
shed config and the host-agent rather than configured here.

## Preferences (GUI)

Open with the menu-bar dropdown → **Preferences…** (or IPC `ui.open_preferences`). Exactly
three values persist, under the standard suite `ai.stridelabs.ShedDesktop`:

| Section | Setting | Stored as | What it does |
|---|---|---|---|
| **General** | Launch at login | OS login-item registration (`SMAppService`), *not* UserDefaults | Registers/unregisters the app as a login item. |
| **Terminal** | Command template (`{cmd}` placeholder) | `terminalTemplate` | Template for the terminal launch command; empty ⇒ Terminal.app. E.g. `ghostty -e {cmd}`. |
| **Approval policy** | Default mode | `defaultApprovalMode` | Default response when the host agent delegates a request: `touchid` (Touch ID each time, default), `prompt`, `approve` (auto), `deny` (auto). |
| **Per-namespace overrides** | ssh-agent / aws-credentials / docker-credentials → Inherit \| a mode | folded into `policyRules` (JSON) | Pins an approval mode for one namespace (only `ssh-agent` is gated today; the rest are audit-only). |
| **Per-shed overrides** | list of `(server, shed)` auto-approve rows | folded into `policyRules` (JSON) | Per-`(server, shed)` "always allow" grants (added by the **Always allow** button on an approval card); remove with the ✕. |
| **Hosts** | read-only list with reachability + `host:port` | — (reflects live state) | Read-only mirror of `~/.shed/config.yaml` — manage hosts with the `shed` CLI. |

So there are exactly **three** persisted keys: `terminalTemplate`, `defaultApprovalMode`,
and `policyRules` (a JSON blob holding all per-namespace + per-shed rules). The full policy
model is in [Credential approvals](approvals.md). The `policyRules` blob is only written on a
successful encode (never wiped), so overrides survive relaunch.

## Host list (`~/.shed/config.yaml`)

The app reads the **same file the `shed` CLI writes** to discover hosts. It is parsed
read-only — the app never modifies it. Override the path with `SHED_DESKTOP_SHED_CONFIG`.
Shape (the fields the app reads):

```yaml
servers:
  mini3:
    host: mini3
    http_port: 8080      # default 8080
    ssh_port: 2222       # default 22
default_server: mini3
```

A missing file degrades to an empty host list (no crash).

## Host-agent approval (`extensions.yaml`)

Whether the credential-approval gate is active is configured on the **host agent**, not in
this app — see [Credential approvals](approvals.md). The app auto-connects to the agent's
socket (default `~/Library/Application Support/shed/host-agent.sock`) when it's serving one.

## Environment variables

Normal use needs none of these. They exist for the test harness, packaging, and release.

### Runtime (read by the app / `shedctl`)

| Var | Purpose |
|---|---|
| `SHED_DESKTOP_TEST_MODE` | `=1` → hermetic test mode: all HTTP clients hit the mock, `terminal.open` + Sparkle are disabled, `policy.set` is enabled, and `identify` echoes the flag. |
| `SHED_DESKTOP_MOCK_BASE_URL` | Redirects every shed-server client at one in-process mock (test mode); echoed by `identify`. |
| `SHED_DESKTOP_SHED_CONFIG` | Override the `~/.shed/config.yaml` path. |
| `SHED_DESKTOP_HOST_AGENT_SOCKET` | Override the host-agent UDS path the approval client dials (a fake agent, in tests). |
| `SHED_DESKTOP_STATE_DIR` | Redirect the app's state dir (the `audit.jsonl`). Must be absolute; does **not** move the control socket/lock. |
| `SHED_DESKTOP_DEFAULTS_SUITE` | Scope `UserDefaults` to a throwaway suite (tests). |
| `SHED_DESKTOP_SOCKET` | Override the IPC socket path `shedctl` connects to. |
| `SHED_DESKTOP_TEST_TIMEOUT_SCALE` | Multiply the harness's `wait_until` budgets (slow CI). |

### Build / release (read by `scripts/` + the release workflow)

| Var | Purpose |
|---|---|
| `SHED_DESKTOP_VERSION` | Override the version (else the top-level `VERSION` file). |
| `SHED_DESKTOP_DEVELOPER_ID_IDENTITY` | Developer-ID signing identity; absent ⇒ ad-hoc sign (notarization path stays inert). |
| `SHED_DESKTOP_ALLOW_UNSIGNED` | `=1` lets bundling continue when `codesign` is missing/failing. |
| `SHED_DESKTOP_DMG_FANCY` | `=1` uses `create-dmg` for a styled DMG (off on headless runners). |
| `SHED_DESKTOP_TAG` / `_APPCAST` / `_SIGN_FILE` / `_REPO` / `_MIN_MACOS` | Inputs to `scripts/update-appcast.py` (tag, appcast path, Sparkle signature file, `owner/repo`, min macOS). |
| `SHED_EXTENSIONS_SRC` | Path to the `shed-extensions` checkout that `scripts/live-verify.sh` builds the real Go host-agent from (default `../shed-extensions`). |

See [RELEASING.md](https://github.com/charliek/shed-desktop/blob/main/RELEASING.md) for the
release flow and the Sparkle/secret/ruleset setup.
