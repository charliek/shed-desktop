# shed-desktop

> ## ⚠️ Moved to the shed monorepo
>
> Development of shed-desktop has moved into [charliek/shed](https://github.com/charliek/shed) (the desktop code lives under `desktop/` + `crates/`; see `docs/discovery/monorepo-consolidation.md` there for the design).
>
> **One final release still ships from this repo** — planned **v0.0.14**, whose only change is repointing the Sparkle `SUFeedURL` to the new feed (`https://charliek.github.io/shed/appcast.xml`). That release lets existing installs migrate to the new update feed automatically, without a reinstall.
>
> After it lands, this repository will be **archived** and stays browsable for history. GitHub Pages stays up, serving the frozen old appcast as a permanent fallback. All future desktop releases ship from the monorepo on shed's version line — desktop jumps from `0.0.x` to `0.8.x+` (a forward version jump, which is safe for Sparkle and apt upgrades).

A native macOS menu-bar application that ties the [shed](https://github.com/charliek/shed)
toolchain — shed, [shed-extensions](https://github.com/charliek/shed-extensions), and the
remote-control patterns from
[shed-remote-agent](https://github.com/charliek/shed-remote-agent) — into one resident
control surface.

It lists and creates sheds across hosts, launches Claude remote-control agents, gates
credential requests from the host agent (the headline feature), shows per-host disk usage,
and surfaces a live activity feed. It is a coordinator: it runs no sheds and holds no
credentials.

Docs: <https://charliek.github.io/shed-desktop/> · Architecture:
[reference/architecture](https://charliek.github.io/shed-desktop/reference/architecture/)

## Install

Download the latest `ShedDesktop-<version>.dmg` from
[Releases](https://github.com/charliek/shed-desktop/releases), drag it to Applications, then
run once: `xattr -dr com.apple.quarantine /Applications/ShedDesktop.app` (ad-hoc signed, not
yet notarized). It auto-updates via Sparkle thereafter. Or build from source:

```bash
make bundle && open build/ShedDesktop.app   # requires Xcode 16+ (Swift 6), macOS 14+
make dmg                                    # build/ShedDesktop-<version>.dmg
```

## Drivable + testable

The app exposes a JSON IPC control socket and an in-process screenshot op, so it can be
driven and verified by an automated agent — no human clicking:

```bash
shedctl identify
shedctl ui navigate agents
shedctl screenshot --surface window --scale 2 --out /tmp/shot.png
```

The functional harness (`make e2e-ci`) launches a real app pointed at an in-process mock
shed-server and asserts via the IPC socket — fully hermetic. See
[Test automation](https://charliek.github.io/shed-desktop/development/test-automation/).

## Development

```bash
make build     # swift build
make test      # swift test (ShedKit unit tests)
make e2e-ci    # hermetic functional harness
make docs-serve
```

## License

MIT — see [LICENSE](LICENSE).
