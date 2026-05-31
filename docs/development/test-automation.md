# Test automation

The app is built to be driven and observed by an automated agent, so changes are verified
by running the real app — not by a human clicking. Two layers:

## Unit tests (`swift test`)

Pure logic in `ShedKit`: config parsing, model decoding against real API shapes (including
`{"sheds": null}` and mixed timestamp formats), the SSE parser, the IPC envelope, and —
in later milestones — the remote-control classifier and the approval policy engine. No
running UI required.

## Functional harness (`tools/shedtest`, pytest)

Drives a **real** ShedDesktop.app over the [IPC socket](../reference/ipc.md) and asserts on
state via `ui.state` / `sheds.list`, plus screenshot checks. It is fully **hermetic**:

1. A stdlib `ThreadingHTTPServer` (`mockserver.py`) stands in for `shed-server` on an
   ephemeral `127.0.0.1` port, serving fixture JSON the test can mutate directly.
2. The harness launches the app with `SHED_DESKTOP_TEST_MODE=1` and
   `SHED_DESKTOP_MOCK_BASE_URL=…`, so every HTTP client is redirected to the mock — no real
   shed-server is touched and nothing leaves the box.
3. `identify` is checked up front to confirm the run is actually hermetic.
4. Tests use condition-waits (`wait_until`), never sleeps; the timeout budget scales from
   `SHED_DESKTOP_TEST_TIMEOUT_SCALE` for slower CI runners.

```bash
make e2e-ci       # fresh, hermetic, mock-backed
```

## Screenshots

`app.screenshot` renders a window's content view to a PNG in-process (no screen-capture
permission, works occluded/off-screen). The harness asserts the PNG decodes and matches
`app.window_metrics`; an agent can also read the PNG directly to eyeball a change.

```bash
shedctl ui show-window
shedctl screenshot --surface window --scale 2 --out /tmp/shot.png
```
