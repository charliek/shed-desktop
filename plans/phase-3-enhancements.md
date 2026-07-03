# Phase 3 — Close out the enhancements backlog (before the Flutter spike)

Status: **panel-reviewed 2026-07-02 (Codex + Kimi K2.6 + CodeRabbit) — findings folded.**
Branch: **`feat/rust-core`** (single branch, as with Phase 1/2). Ends with the branch
**CI-green on a PR and ready to merge to `main`**.

## Why this phase

Phase 2 shipped the multi-client story (Rust core as the macOS default; a `shed-gtk`
GTK/Linux client; a `.deb` that install-validates). Before the next roadmap direction (a
Flutter mobile spike), we **close the enhancements backlog** that Phase 2 accrued: real
`.deb` release wiring, GTK-client robustness, a Linux CLI, CI hardening, a unified
cross-client test harness, an adversarial coverage pass, and docs — and we finally run the
branch's CI on real GitHub runners and merge it.

## Locked decisions (from the design discussion, 2026-07-02)

1. **`.deb` package + binary = `shed-desktop`** (crate stays `shed-gtk`; the produced
   `[[bin]]` is renamed to `shed-desktop`, mirroring roost's `roost-linux`→`roost`). The
   internal socket/env stay `SHED_GTK_*` (low churn). apt glob: `shed-desktop_*.deb`.
2. **Unified versioning.** One `git tag vX.Y.Z` cuts the macOS DMG + Sparkle appcast **and**
   the `shed-desktop` `.deb`, all at the top-level `VERSION`. `update-version.sh` also bumps
   `core/Cargo.toml [workspace.package].version` **and regenerates `core/Cargo.lock`** so
   there is one version everywhere and `--locked` CI stays green.
3. **Defer the "delete a Swift implementation" items** (retire the Swift `URLSession` path;
   unify config discovery / retire the Swift `ShedConfig` parser) to a **future Rust-core-only
   phase** — captured in `plans/phase-4-rust-core-only.md` (stub written this phase). Phase 3's
   core-parity work is the two **test/guard** items only.
4. **Unify the functional harness** into one `--target mac|gtk` suite (roost's model) that
   drives the shared IPC ops against **both** clients; Mac-only ops stay Mac-gated.
5. **Adversarial coverage audit + gap-fill** across `shed-core` + `shed-gtk` + the Swift
   units, plus a full negative/error/edge expansion of the GTK suite.
6. **CI items in scope:** the `changes` path-filter job + an `x86_64` Linux leg. Deferred:
   the release-bundle size gate in CI, and snapshot-caching the GTK box.
7. **Deferred (unchanged):** the native-Linux test skill; M6 GTK approval pane (after Flutter).

## Panel review — incorporated

All three reviewers converged on four load-bearing corrections, now folded below:
- **Single-instance must NOT rely on GTK `GApplication` uniqueness** — it's D-Bus-based and
  absent on macOS-Homebrew GTK and under CI `xvfb-run`, so a second launch would spawn a
  socket-less second window. Instead: on lock contention, send an explicit `app.activate`
  IPC op to the running socket and return **before** `app.run()` (roost's actual path). Adds
  a new `app.activate` op (P3.3).
- **`update-version.sh` must regenerate + commit `core/Cargo.lock`** (workspace crates pinned
  at `0.0.1`; three CI jobs build `--locked`) — else every post-bump `--locked` run fails
  (P3.5a).
- **`release.yml` needs a dedicated `create-release` job** — today the Release is created
  inside the slow mac job; a parallel `linux` upload would race it (P3.5b).
- **The rename must keep CI green in the same commit** — `ci.yml`'s and `Makefile`'s
  `shed-gtk_*.deb` globs + the `shedgtktest` BIN path (P3.1), and the `ci-success` gate must
  become `if: always()` before path-filtering or a skipped job blocks the PR forever (P3.2).

Two items flagged for the maintainer (proceeding with the locked choice; say the word to change):
- **Ordering — `shedctl` before `.deb`-release (kept).** Codex suggested release-first to
  keep the first apt release's blast radius small; Kimi/CodeRabbit keep `shedctl` first so the
  package ships complete when the wiring lands. Since no real tag is cut this phase, we keep
  `shedctl`→release; the maintainer can still ship shed-desktop-only in the first real release.
- **The `core/Cargo.toml` bump is cosmetic** (no shipped artifact reads it — the `.deb`
  version is tag-derived, `bundle.sh` uses `VERSION`), so its only cost is the ~100-line
  `Cargo.lock` churn. We keep decision #2 (one version everywhere, roost's proven pattern);
  the alternative is to freeze `core/Cargo.toml` and let the tag be the sole artifact version.

## Milestones

Each milestone is one (or a few) commits, **each green on its own** (a commit that leaves CI
red is a defect), each through the per-commit flow (`/simplify` → `/codex:rescue` [fallback
`/cursor:rescue`] → tests+lint → commit). This is one branch/PR (single-branch convention);
each milestone is independently green and *could* be its own PR if we ever split.

### P3.0 — Get the branch onto real CI (a PR)

- `git push -u origin feat/rust-core`; open a **draft PR** → `main` (CI runs `on:
  pull_request`; a plain branch push does **not** trigger it).
- Triage the first real run of the jobs built in Phase 2 but never run on GitHub runners:
  `core-linux`, `gtk-build`, `e2e-gtk` (Xvfb), `deb`. Fix runner-specific issues as normal
  commits.
- **Accept:** the PR exists, CI runs, failures understood (fixed or ticketed). Draft until P3.9.

### P3.1 — Rename the produced binary/package to `shed-desktop` (CI stays green)

The crate + lib `shed_gtk`, all `SHED_GTK_*` env vars, and the `shed-gtk` runtime-dir/socket
path **stay** (locked low-churn decision — documented as intentional; `-p shed-gtk` and
`--exclude shed-gtk` at `Makefile:47` are the *crate* and correctly stay). Only the
user-facing binary/package/app-id/desktop/icons become `shed-desktop`. Full sweep:
- `core/shed-gtk/Cargo.toml`: `[[bin]] name = "shed-desktop"` (path stays `src/main.rs`).
- `src/main.rs`: `APP_ID = "ai.stridelabs.ShedDesktop"`; dev doc-comments (`main.rs:1`,
  `lib.rs:4`, the `ipc.rs` bind comment).
- `packaging/shed-gtk.desktop` → `packaging/shed-desktop.desktop`
  (`Exec`/`StartupWMClass`/`Icon`; user-facing `Name=Shed` may stay); nfpm dst
  `…/applications/ai.stridelabs.ShedDesktop.desktop`.
- `packaging/nfpm.yaml`: `name: shed-desktop`, bin dst `/usr/bin/shed-desktop`, icon paths,
  the `Output:` header comment; **rename the icon files**
  `packaging/icons/hicolor/{256x256,512x512}/apps/shed-gtk.png` → `shed-desktop.png`.
- `linux/scripts/build-deb.sh` (stage `target/release/shed-desktop`), `validate-deb.sh:23`
  (`command -v shed-desktop`), `deb_identify_check.py` (`xvfb-run -a shed-desktop`).
- **`.github/workflows/ci.yml:168`** and **`Makefile:93`**: the `out/shed-gtk_*.deb` glob →
  `shed-desktop_*.deb` (CodeRabbit C3 — else `deb-validate` runs with no arg → red).
- **`tools/shedgtktest/ui.py` `BIN`** → `core/target/debug/shed-desktop` (a temporary compat
  shim so the `e2e-gtk` job stays green until P3.6 retires the harness).
- `tools/shed/build-in-shed.sh` (`SHED_GTK_BIN`→`…/debug/shed-desktop`; `SHED_BUILD_PKG` stays
  the `shed-gtk` crate), `tools/shed/shed-test.sh`, `packaging/copyright`.
- `Makefile` `gtk-run` → `cargo run -p shed-gtk --bin shed-desktop`.
- **Accept:** `make gtk-build`; `make deb-validate` (clean-container `identify` →
  `platform=gtk, core=rust`); the GTK e2e (Mac-native); and a
  `rg -n 'shed-gtk_|ShedGtk|debug/shed-gtk' -g'!*.lock'` sweep showing only intentional
  crate/env/socket references remain. User-facing docs are deferred to P3.8; dev
  code-comments updated now.

### P3.2 — CI hardening: `changes` path-filter + `x86_64` leg (+ the ci-success fix)

- `changes` job (`dorny/paths-filter`, mirroring roost) gating `core-linux`/`gtk-build`/
  `e2e-gtk`/`deb`; `swift` stays always-on.
- **Rework `ci-success` FIRST (CodeRabbit M2 — load-bearing):** it is currently a plain
  `needs: […]` echo (`ci.yml:182-187`); once jobs are `if:`-gated, a skipped needed job makes
  the plain gate *also* skip → the required check never reports → the PR is blocked forever.
  Change to `if: always()` + a step reading `needs.*.result` that passes on `success`+`skipped`
  and fails on `failure`/`cancelled`.
- Add `x86_64-unknown-linux-gnu` to `core-linux` (`arch` matrix; `fail-fast: false`). Repo is
  **public** so `ubuntu-*-arm` is free; verify arm64 runners are enabled on the first PR run.
- **Accept:** a docs-only push skips the Linux jobs **and** `ci-success` still reports success;
  both `core-linux` arches green.

### P3.3 — GTK robustness: single-instance (explicit IPC activate) + parallel `list_sheds`

- **Single-instance** (`core/shed-gtk/src/single_instance.rs`, roost's *actual* path):
  `fs2::try_lock_exclusive` on a pidfile in the **`shed-gtk` runtime dir**
  (`<socket_dir>/shed-desktop.lock`), acquired in `main.rs` **before** the IPC socket bind —
  this is what makes `IpcServer::bind`'s unconditional `remove_file` (`ipc.rs:249`) safe. Keep
  the panic-on-bind-failure only in the **lock-acquired** branch. On `AlreadyHeld`: spin a
  tiny current-thread runtime, connect to the existing socket, send a new **`app.activate`**
  op, then `return Ok(())` **before** `app.run()` — do **not** rely on GTK `GApplication`
  D-Bus uniqueness (absent on macOS-Homebrew GTK and under CI `xvfb-run` → would spawn a
  second, socket-less window).
- **New `app.activate` IPC op** (`UiRequest::Present` → `window.present()`) on the GTK handler.
- **Parallel hosts** (`backend.rs` `list_sheds`): `join_all` the per-host fetches; a slow/down
  host no longer stalls the rest (shed-core's 8s per-request timeout still bounds the worst).
- **Tests (this milestone):** a `single_instance` **lib-test** (second `acquire` → `AlreadyHeld`);
  `list_sheds` unit tests for **zero hosts → []**, **one erroring host → the other's sheds**,
  and **`{"sheds": null}` → []** (defensive decoder). The **second-launch e2e** (second process
  exits 0 within 5 s, primary PID unchanged, socket still serving, no second window) lands in
  **P3.6**, where the unified harness expresses "second launch" cleanly.
- **Accept:** lib/unit tests green on Mac-native + the Linux jobs.

### P3.4 — Linux `shedctl` CLI in the `.deb`

- New **`core/shedctl`** crate (headless UDS client, **no GTK dep**), a `[[bin]] shedctl`: a
  generic driver (`shedctl <op> [--param k=v …]` → `{id,op,params}` → prints `result`) +
  convenience subcommands mirroring the Mac `shedctl` subset (`identify`, `sheds list`,
  `screenshot --out`, `dashboard dump`, lifecycle). Socket default = the shed-desktop path
  (honor `SHED_GTK_SOCKET` + `--socket`).
- Add `shedctl` to **both** `members` **and** `default-members` in `core/Cargo.toml` (headless
  ⇒ `make core-test` [`cargo test`, default-members] and `core-lint` [`--workspace --exclude
  shed-gtk`] cover it on Mac; `build-core.sh` is `-p shed-core-ffi`-scoped so the Mac bundle is
  unaffected — confirmed). `build-deb.sh` builds `-p shedctl`; nfpm ships `/usr/bin/shedctl`.
- Note the intentional **two-`shedctl` split**: Swift `Sources/shedctl` (bundled in `.app`,
  macOS) and this Rust `core/shedctl` (in the `.deb`, Linux) — same name, different platforms.
- **Tests:** a frame round-trip unit test; an e2e driving one op through `shedctl` (folds into
  the unified harness in P3.6).
- **Accept:** `cargo test -p shedctl`; the `.deb` ships `shedctl`; the e2e passes; the Mac
  bundle size is unchanged.

### P3.5a — Unified version bump (`update-version.sh` + `Cargo.lock`)

- Extend `scripts/release/update-version.sh`: after writing `VERSION`, `cd core` and bump
  `core/Cargo.toml` with an **anchored** `sed 's/^version = "…"/…/'` (the only line-anchored
  match — deps are inline, so an unanchored replace would corrupt them), then
  `cargo update --workspace --offline` to **regenerate `core/Cargo.lock`**. Verify each:
  `grep -q '^version = "$V"'` on `core/Cargo.toml` **and** `core/Cargo.lock`. Keep the strict
  `X.Y.Z` regex (the downstream `*-*` prerelease-skip is future-proofing, unreachable via this
  script — matches roost).
- **Accept:** `update-version.sh 0.0.0` (plain `X.Y.Z`) bumps `VERSION` + `core/Cargo.toml` +
  `core/Cargo.lock`; `(cd core && cargo build --locked)` succeeds; `git checkout -- .` reverts
  clean.

### P3.5b — `.deb` release wiring (release.yml restructure + apt dispatch)

- **Restructure `release.yml` (Codex/CodeRabbit C2 — the crux):** today the mac `build` job
  creates the Release inline (`release.yml:118`); a parallel `linux` upload would race a
  not-yet-created Release. Adopt roost's shape: a dedicated **`create-release`** job (idempotent
  `gh release view … || gh release create`) → **`mac`** + **`linux`** (both `needs:
  create-release`, both `gh release upload --clobber`) → **`dispatch-apt-charliek`**
  (`needs: linux`).
- **`linux` matrix:** `ubuntu-24.04`/amd64 + `ubuntu-24.04-arm`/arm64, `fail-fast: false`;
  install GTK4 + nfpm 2.46.3 (tarball, `amd64→x86_64` arch map); assert `dpkg
  --print-architecture` **== matrix.arch** before upload; `build-deb.sh "${GITHUB_REF_NAME#v}"`;
  `gh release upload "$tag" out/*.deb --clobber`.
- **`dispatch-apt-charliek`:** skip prereleases (`*-*`); mint a token via
  `actions/create-github-app-token@v3` (`RELEASE_BOT_CLIENT_ID` + `RELEASE_BOT_APP_KEY`,
  already set; scoped `owner: charliek, repositories: apt-charliek`); `gh api
  repos/charliek/apt-charliek/dispatches -f event_type=publish -F
  client_payload[package]=shed-desktop -F client_payload[tag]=$tag`.
- **Triple version guard (CodeRabbit M1):** extend the release-time tag-check to assert
  tag == `VERSION` == `core/Cargo.toml` version.
- **`sanity-check-app.yml`:** add it (content from the release-workflows template
  `references/workflows/sanity-check-app.yml.template`, or roost's — provided inline, not
  assumed from the skill) with the **apt-charliek** cross-repo block.
- **apt-charliek:** add `{name: shed-desktop, repo: charliek/shed-desktop, glob:
  "shed-desktop_*.deb", include_prerelease: false}` to `packages.yaml` + the README row
  (separate repo — prepared locally; **maintainer merges** the small PR).
- **`RELEASING.md`:** document the `.deb`/apt flow. Drive via **`/release-workflows:setup`**
  (a global plugin skill — survey → apt pipeline → compose).
- **Accept:** `actionlint` clean; the `needs:` graph reviewed (mac/linux both `needs:
  create-release`; dispatch `needs: linux`; `gh release upload` has a producing dependency);
  P3.5a's dry-run still green. **No real tag cut.** `sanity-check-app` (maintainer, Actions UI)
  reaches apt-charliek.

### P3.6 — Unify the functional harness (`--target mac|gtk`)

- `--target` (option → `$SHED_TEST_TARGET` → default `mac`) session fixture; `ui.py`
  `TARGETS`, `socket_path(target)`, `launch(target)` (mac `open` `.app` + `SHED_DESKTOP_*`;
  gtk subprocess `shed-desktop` + `SHED_GTK_*`), both → the shared in-process mock.
  **`quit(target)` stays a switch** — the Mac path (osascript → pkill → `defaults delete` →
  unlink sock/lock) must **not** be flattened into GTK's (`terminate`/`kill` + temp
  `XDG_RUNTIME_DIR`).
- **One `IPCClient` base** (the wire protocol is identical) + target-specific op helpers.
  **`dashboard_rows(target)` → `List[{name,status,host}]`:** mac `call("ui.state")["sheds"]`,
  gtk `call("dashboard.dump")["rows"]`. Include **`sheds.refresh`** in the shared contract
  (gtk `dashboard.dump` reads last-rendered state; the per-target reset must `mock.reset()`
  **then** `sheds_refresh()` for gtk — CodeRabbit M3).
- **Mac `create.cancel` parity (CodeRabbit H2):** the Mac IPC handler has
  `create.start`/`create.status` but **no `create.cancel`** (the core adapter already exposes
  `createCancel`); add the ~3-line arm so the shared cancel test runs on both.
- **Fixtures branch on `--target`** (the Mac fake-host-agent + policy-reset setup must not run
  under gtk, and vice-versa). **Mac-only suites** (approvals/RC/activity/notifications/nav/
  prefs) gated with `@pytest.mark.skipif(target != "mac", …)`, not per-test `if`. Timeout scale
  respects both `SHED_DESKTOP_TEST_TIMEOUT_SCALE` and `SHED_GTK_TEST_TIMEOUT_SCALE`.
- **Retire `tools/shedgtktest` only after every one of its 11 fns has a named home**
  (CodeRabbit M3): create ×3 (incl. `test_create_cancel_drops_it` → needs the Mac cancel arm;
  `test_sheds_list_during_create_no_deadlock` → keep as a tokio-independence guard), dashboard
  ×2, identify ×1, lifecycle ×1, screenshot ×1 (keep the "non-empty PNG" leniency). Land the
  **second-launch flock e2e** (from P3.3) here.
- `Makefile` `e2e-gtk` → `pytest tools/shedtest --target gtk`; `ci.yml` `e2e-gtk` likewise;
  `make e2e-ci`/`e2e-swift` default `--target mac`.
- **Accept:** full suite green on **both** `--target mac` (macOS) and `--target gtk` (Mac-native
  + Linux Xvfb); `tools/shedgtktest` deleted; a checklist maps all 11 old fns to new homes.

### P3.7 — Adversarial coverage audit + gap-fill (time-boxed)

- Read-only audit fan-out (parallel `Agent`s per surface: `shed-core`, `shed-gtk`+IPC, Swift
  units/e2e, the create/SSE/token/TLS/config edges) framed *"what regression slips through
  today?"* → a deduped gap list. **Time-box: ~2 h per surface; any gap needing > ~1 day is
  ticketed to Phase 4 / the enhancements collector, not built here.**
- Fill the real gaps: GTK negative/error/edge (create-`error` event, cancel mid-stream,
  down/errored host, malformed/oversized IPC frame, unknown op, `dashboard.dump` **before first
  render** → `[]`, `IpcServer::bind` under a symlinked parent), plus any core/Swift gaps; lift
  the thin `shed-gtk` lib-test count.
- **Accept:** new tests green on both targets; the audit's must-fix list empty or ticketed.

### P3.8 — Docs, backlog collector, and plan hygiene

- **Rewrite `docs/enhancements.md` into a clean, forward-looking collector** (maintainer's ask):
  - **Remove finished items entirely** — no struck-through/`[x]` cruft. What shipped lives in
    git history, the phase plans, and the roadmap's "complete" view; the backlog carries **only
    open work**. (Everything landing this phase comes out; the two deferred items move to Phase 4.)
  - **One evaluation-ready format:** a per-category table with columns **Item · Value · Effort ·
    Description** + a short **legend** (Value High/Med/Low; Effort XS/S/M/L) — the same axes as
    the Phase-2 status dashboard.
  - **Set up to collect new items:** a header stating the purpose + a one-line "**How to add**"
    convention (append a row with a Value/Effort estimate) + a pointer that *shipped items are
    logged in the phase plans + roadmap, not here.*
  - **Tighten the metric count** ("64 pytest fns / 37 IPC ops") wherever it appears.
- `docs/roadmap.md`, `docs/reference/{architecture.md,rust-core.md}`, `CLAUDE.md`: reflect the
  shipped `.deb` pipeline, the `shed-desktop` binary/package, `shedctl`, the `app.activate` op,
  and the unified harness.
- `plans/phase-3-enhancements.md`: tick milestones as they land.
- `plans/phase-4-rust-core-only.md`: **new stub** capturing the deferred "delete-Swift" items
  (retire `URLSession`, unify config via FFI).
- Refresh `plans/phase-2-next-session.md` into a Phase-3/next kickoff.
- **Accept:** docs match reality; no stale "Phase 2 builds the .deb but shipping is a
  follow-up" claims remain.

### P3.9 — Merge readiness

- CI green on the PR; mark **ready for review**.
- The **merge to `main` is the maintainer's call** — confirm before merging. Cutting the first
  `.deb`-bearing release (a real tag) is a separate, later step (`/release-workflows:release`).

## Hard constraints (carried from Phase 1/2 + repo conventions)

- `shed-core` stays **pure** (no UniFFI/SwiftUI; the GTK app + `shedctl` link it directly).
- Swift 6 strict concurrency; the tokio↔glib **panic-trap rules** for any `shed-gtk` change
  (spawn shed-core futures on the runtime, `.await` the JoinHandle inside
  `glib::spawn_future_local`; never hold a `RefCell` borrow across `.await`; flatten `!Send`
  GTK objects to data before crossing threads).
- Keep the Mac build **GTK-free**: `shed-gtk` stays out of `default-members` (so `make
  core-test` = bare `cargo test` skips it); `shedctl` (no GTK) joins `default-members`;
  `core-lint` stays `--workspace --exclude shed-gtk`.
- **Never** run real notarization or touch `.secrets/apple.env`; do not cut a real release tag
  autonomously.
- Keep every commit green + drivable (new behavior ⇒ an IPC op + harness coverage). Trailers on
  every commit (`Co-Authored-By` + `Claude-Session`).

## Maintainer actions (GitHub-side — flagged, not auto-done)

- **apt-charliek PR:** merge the `packages.yaml` + README addition (I'll prepare it).
- **`sanity-check-app`:** run it once from the Actions UI to confirm the App reaches
  apt-charliek (secrets already present; App already on apt-charliek via roost — expected
  green). Also confirm arm64 runners are enabled (public repo → free) on the first PR run.
- **The merge to `main`** and **the first release tag** are yours.

## Deferred → future phases (logged, not dropped)

- **Phase 4 (Rust-core-only):** retire the Swift `URLSession` path (+ the `=0` fallback + its
  e2e leg) and unify config discovery (retire the Swift `ShedConfig` parser via the FFI) —
  after the Rust default has shipped ≥2 releases.
- Native-Linux test skill; release-bundle size gate in CI; snapshot-cache the GTK box; M6 GTK
  approval pane (after Flutter).
