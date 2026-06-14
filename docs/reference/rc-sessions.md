# Remote-control sessions (the Agents pane)

The **Agents** pane drives `claude remote-control` (and REPL / shell) sessions
inside a shed: detached `tmux` sessions named `rc-<slug>`, created and torn down
over SSH. The pane lists them with a live state, a "made by … · age" provenance
line, an **Open console** button (attach a terminal to the session's tmux), an
**Open in Claude** button (the `claude.ai/code` URL), and a kill button.

## RC Session Convention v1 (`SHED_RC_*`)

shed-desktop is a conformant client of the tool-neutral **RC Session Convention
v1** (published by `shed-remote-agent`; spec:
`docs/reference/rc-session-convention.md` there). The tmux session is the single
source of truth — all durable metadata lives in its session environment, and
`state`/`url` are always derived fresh from the pane, never stored. This lets
shed-remote-agent, shed-desktop, the `shed` CLI, and future clients discover,
classify, attach to, and tear down each other's sessions without a registry.

Metadata is written once at create with `tmux new-session -e KEY=value …` and
read back with one `tmux show-environment` dump per session:

| Key | Meaning |
|-----|---------|
| `SHED_RC_V` | Schema version (a positive integer; `1`). |
| `SHED_RC_ID` | Stable opaque id (a lowercase UUIDv4), generated once at create. |
| `SHED_RC_DISPLAY_NAME` | Human name; also `claude --name`. |
| `SHED_RC_KIND` | `agent` \| `repl` \| `shell`. |
| `SHED_RC_WORKDIR` | Working directory at create. |
| `SHED_RC_CREATED_BY` | Provenance `<tool>/<version>`, e.g. `shed-desktop/0.0.8`. |
| `SHED_RC_CREATED_AT` | Creation time, RFC 3339 UTC with a trailing `Z`. |
| `SHED_RC_TARGET` | Optional, advisory target label (`shed:<name>@<host>`); non-authoritative. |

Values are written **raw** — `sshArgv` shell-quotes each argv token, so tmux
(≥ 3.0) stores each `KEY=value` verbatim, and a multi-word display name round-
trips unescaped. Writers reject control characters (a newline would corrupt the
line-oriented list parser).

### Managed vs legacy

A session is **managed** when `SHED_RC_V` is a positive integer (compared as
decimal text, so a very large version stays managed rather than overflowing).
A session with a higher version is still managed — known v1 fields are rendered,
unknown keys ignored, and the session is **never dropped** (forward-compat).

Any `rc-*` session without a valid `SHED_RC_V` is **legacy/unmanaged**: it is
still listed and killable, but rendered with defaults (`kind = agent`, a
`<shed>/<slug>` fallback name, the default workdir), any stray `SHED_RC_*` /
`SRA_*` values are ignored, and the Agents pane shows a `legacy` badge and
**confirms before killing** it.

> **Clean break.** Earlier builds used an app-named `SRA_*` prefix
> (`SRA_DISPLAY_NAME` / `SRA_KIND` / `SRA_WORKDIR`). That prefix is **no longer
> written or read**. Until every tool you use adopts v1, each renders the other's
> older sessions as legacy/unmanaged (still attachable/killable, defaults only);
> kill + recreate a session to restore its metadata.

## Derived state

`state` and `url` are computed from a `tmux capture-pane` by the pure classifier
(`rc.classify` over IPC), never stored:

| `state` | Meaning |
|---------|---------|
| `starting` | No URL / status line yet (incl. `claude` still in first-run setup). |
| `ready` | Terminal-good for the kind (a URL for `agent`/`repl`; any output for `shell`). |
| `reconnecting` | `claude remote-control` is reconnecting (`agent`). |
| `needs-trust` | `claude` refused — workspace not trusted (attach via the console button to trust). |
| `needs-auth` | `claude` needs a `claude.ai` login (attach + `claude auth login`). |
| `dead` | The tmux session is gone. |

## Transport

Listing pipes a single batched script to a remote `bash` over **stdin** (not
`bash -c`) and runs tmux directly: on shed images where the user has no
controlling terminal, tmux invoked under `bash -c` fails with "open terminal
failed: not a terminal", but works when bash reads from stdin. Random per-call
markers (`@@RC:<nonce>:…`) frame each session's env dump + pane so neither pane
text nor a metadata value can forge a delimiter.

See also the [shed follow-up](https://github.com/charliek/shed/issues/199) to
surface this metadata over `GET /api/sessions` for HTTP-only clients.
