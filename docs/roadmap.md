# Roadmap & ideas

Directions we may take shed-desktop, not commitments or a schedule. Today's app is a
complete control surface — dashboard + lifecycle, the remote-control launcher, the
SSH-credential approval gate, the System (disk) pane, and Sparkle auto-update. The items
below are deliberately *out of scope right now*; they're recorded so the gaps are explicit.

## Credentials

- **Gate AWS + Docker, not just SSH.** The host agent already streams an all-namespace audit
  feed, and the approval protocol is namespace-agnostic; only `ssh-agent` is *gated* today.
  Extending the gate to `aws-credentials` and `docker-credentials` is mostly wiring on the
  agent side — gated behind a clean policy story so frequent STS refreshes don't become
  prompt fatigue. See [Credential approvals](reference/approvals.md).
- **Auto-approve with constraints** — e.g. docker limited to a registry allowlist.

## Broader control surface

The shed-server HTTP API exposes more than the app surfaces today. Natural additions, each
independently useful:

- A **global sessions** view (`/api/sessions` + the RC list, merged).
- **Snapshot** management (`/api/snapshots`).
- **Image** management (`/api/images`).
- **System prune** (`/api/system/prune`) alongside the existing disk-usage view.
- **Port-forwarding** UI on top of `/api/sheds/{name}/connect/{port}`.

## Distribution

- **Notarized builds.** Releases are ad-hoc signed today (auto-update authenticity rests on
  the Sparkle EdDSA signature). A Developer-ID certificate + notarization would remove the
  first-launch Gatekeeper step.

## Larger bets

- **Embedded terminal / in-app console** — today the app delegates to the user's terminal
  app; an in-app console (xterm.js in a `WKWebView`, or SwiftTerm) is a revisit only if that
  proves insufficient.
- **In-app host management** — writing `~/.shed/config.yaml` instead of read-only reflection.
- **A Linux/GTK sibling** reusing the UI-free core (`ShedKit`).

Have an idea or a need? Open an issue.
