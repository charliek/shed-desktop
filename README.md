# shed-desktop

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
