# Setup

## Prerequisites

- macOS 14+ on Apple Silicon
- Xcode 16+ (Swift 6 toolchain)
- [uv](https://docs.astral.sh/uv/) for the docs + test harness (Python)

## Common tasks

```bash
make build        # swift build
make test         # swift test (ShedKit unit tests)
make bundle       # assemble build/ShedDesktop.app (ad-hoc signed)
make run          # bundle + open the app
make e2e          # functional harness against the running/auto-launched app
make e2e-ci       # hermetic: fresh app, test mode, in-process mock shed-server
make docs-serve   # live docs preview
make fmt / lint   # swift-format
```

## Layout

```
Sources/
  ShedKit/          # core: HTTP/SSE clients, models, config, IPC, screenshot
  ShedDesktopUI/    # SwiftUI views + AppState
  ShedDesktopApp/   # @main app: AppModel, IPC handler impl
  shedctl/          # CLI driver
Tests/ShedKitTests/ # unit tests
tools/shedtest/     # pytest functional harness + in-process mock server
docs/               # mkdocs site
```

## Style

- Default to no comments; add one only when the *why* is non-obvious (a hidden constraint,
  a workaround, a tricky invariant). Don't comment what well-named code already says.
- Errors are returned/thrown, not logged-and-swallowed.
- Keep `ShedKit` free of SwiftUI so it stays unit-testable.
