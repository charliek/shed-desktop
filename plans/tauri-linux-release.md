# Tauri as the Linux client — retire shed-gtk, merge `feat/rust-core` → `main`

**Status:** PLAN — panel-reviewed (Codex + Kimi K2.6 + CodeRabbit) and folded 2026-07-07. Work
directly on `feat/rust-core` (one commit per sub-milestone; M4 splits into two), then one PR
`feat/rust-core` → `main`. **This effort does NOT cut a release** — no version bump, no tag, no
publish. Finish line: `feat/rust-core` merged to `main`, green, with **Linux = the Tauri `.deb`**
and **`shed-gtk` removed**.

## Mission

Make the **Tauri** client the shipped **Linux** artifact (the `shed-desktop` `.deb`), retire the
dedicated GTK client (`shed-gtk`), and rewire the release pipeline so the Linux `.deb` is built
from Tauri. The **Swift macOS app stays the macOS artifact** (DMG + Sparkle) — untouched (that
migration is phase-4, out of scope). One shared `shed-core`/`shed-app` foundation now backs the
mac Swift app, the Tauri client, and `shedctl`.

## Maintainer decisions (settled 2026-07-07)

1. **`.deb` mechanism = extend the existing nfpm `linux/scripts/build-deb.sh`** (not Tauri's
   built-in deb bundler). Rationale: the Linux artifact is an *exactly-correct multi-binary system
   package* (`shed-desktop` + `shedctl` + polkit policy + `.desktop` + icons) that must `apt`-
   upgrade cleanly over the current GTK `.deb`. nfpm expresses that natively with a guaranteed
   package name and deps *proven* by `deb-validate`; Tauri's app-centric bundler needs escape
   hatches for the same result and has flaky webkit2gtk dep-detection. The future mac→Tauri move
   is orthogonal (it changes the mac **DMG** path, not the Linux `.deb`), so nfpm is not a lock-in.
2. **`shed-gtk` removed LAST, within this same effort** — land + prove the Tauri `.deb` first
   (M1–M3), then delete `shed-gtk` (M4), all as separate commits on `feat/rust-core` before the
   single merge. Linux always has a working artifact at each commit; `main` ends up clean.

## Current-state map (verified 2026-07-07)

- **Release** (`.github/workflows/release.yml`): tag `vX.Y.Z` → `create-release` (verifies tag ==
  `VERSION` == `core/Cargo.toml`) → parallel `build` (mac DMG + appcast) and `linux` (matrix
  `amd64`/`arm64`, runs `./linux/scripts/build-deb.sh`, uploads `out/*.deb`) → `dispatch-apt-charliek`
  (skips `*-*` prerelease tags; `client_payload[package]=shed-desktop`).
- **The `.deb` today** (`linux/scripts/build-deb.sh` + `packaging/nfpm.yaml`): `cargo build
  --release -p shed-gtk -p shedctl` → the `shed-gtk` `[[bin]]` is named `shed-desktop` → nfpm packs
  `shed-desktop` + `shedctl` + `.desktop` + icons; `depends: libgtk-4-1 (>=4.12)`,
  `libadwaita-1-0 (>=1.4)`, `libc6`. Env-driven: `SHED_GTK_VERSION`, `SHED_GTK_ARCH`.
- **`deb-validate`** (`linux/scripts/validate-deb.sh` + `deb_identify_check.py`): `apt install` the
  `.deb` in a clean `ubuntu:24.04` + `xvfb`, launch `xvfb-run shed-desktop` with `SHED_GTK_*` env,
  poll the IPC socket, assert `identify` → `platform=="gtk"`, `core=="rust"`.
- **`shedctl`** (`core/shedctl`): the crate is **GTK-free** (the "gtk" grep hits are doc-strings +
  socket-path comments), BUT its **default socket + env are GTK** (`main.rs:180-197`:
  `SHED_GTK_SOCKET` → `$XDG_RUNTIME_DIR/shed-gtk/shed-gtk.sock`). It is the headless CLI shipped
  IN the `.deb` — to drive the shipped Tauri app it must default to `shed-tauri.sock` (flat, per
  `tauri/src-tauri/src/env.rs:94`) + read `SHED_TAURI_SOCKET`. (Not used on mac — the mac IPC has
  its own `Sources/shedctl`.)
- **Tauri client** (`tauri/src-tauri`, standalone cargo workspace, empty `[workspace]` table): bin/pkg
  `shed-desktop-tauri`, `productName "Shed Desktop"`, `identifier ai.stridelabs.shed-desktop`.
  `bundle.targets: ["app"]` (mac-only, no deb config). Frontend **embedded into the binary** via
  `generate_context!` (no runtime asset dir needed). A plain `cargo build` does NOT run
  `beforeBuildCommand` (only `cargo tauri build` does), so the frontend bundle `tauri/ui/dist`
  must be built separately before/inside the deb build. Linux socket `$XDG_RUNTIME_DIR/shed-tauri.sock`
  (flat; `/tmp/shed-tauri-<uid>/` fallback), env prefix `SHED_TAURI_*`
  (`_TEST_MODE`/`_MOCK_BASE_URL`/`_SHED_CONFIG`/`_SOCKET`/`_HOST_AGENT_SOCKET`), single-instance
  flock (`fs2`, keyed to the socket dir), `identify` → `platform=="tauri"`. Terminal-opener
  resources (`resource_dir()/bin`) are **optional** — absent, the app falls back to a default
  terminal (parity with what GTK shipped). The Linux approval gate shells out to `/usr/bin/pkcheck`
  (`ai.stridelabs.shed-desktop.approve-credential`); the zbus notifier posts with an app-icon
  name (verify the exact string in `tauri/src-tauri/src/approval.rs` — Codex flags it as
  `ai.stridelabs.shed-desktop`, while packaging installs only `shed-desktop.png`).
- **Tauri Linux runtime deps** (the runtime `-0`/`-1` siblings of `Dockerfile.tauri-linux`'s build
  deps, confirmed by `ldd` + `deb-validate`, NOT derived mechanically): `libwebkit2gtk-4.1-0`,
  `libgtk-3-0` (webkit2gtk-4.1 is GTK**3**), `libayatana-appindicator3-1`, `librsvg2-2`,
  `libsoup-3.0-0`, `libc6`. `libssl`/`libxdo` are **intentionally omitted** (not in the Tauri lock
  graph / not needed at runtime — `deb-validate` is the proof; do not add them mechanically).
- **Tauri Linux features landed** (Phase C): lifecycle (start/stop/reset/delete), create-SSE, the
  **native tray menu** (Open Dashboard / Approvals / Preferences… / Quit — no popover on Linux;
  Tauri emits no Linux tray click events, expected), single-instance handoff (`app.activate`),
  approvals spine (polkit gate + zbus notifier), Agents/RC, launch-at-login, and full drivability
  (`identify`, `sheds.list`, `dashboard.dump`, `ui.current_pane`/`navigate`/`show_window`,
  `tray.dump`, `app.screenshot` via scrot). Render-gate-green on real WebKitGTK 2.44.
- **CI** (`.github/workflows/ci.yml`): path-filtered legs `swift`, `core-linux`, **`gtk-build`**,
  **`e2e-gtk`**, **`deb`** (builds the GTK `.deb` + validates; trigger `rust||packaging||ci`,
  installs `libgtk-4-dev libadwaita-1-dev`), `tauri-linux` (`tauri-test-linux` + `tauri-build-linux`
  render gate), `tauri-mac` (`e2e-tauri`), `docs` → the single required `ci-success` gate
  (skipped-by-filter counts as pass; the `needs:` list + result-scan string are load-bearing).
- **`shed-gtk` footprint**: `core/shed-gtk/` (lib/main/app/ipc/env/single_instance); a `members`
  entry (NOT a `default-member`) in `core/Cargo.toml`; `--exclude shed-gtk` in `make core-lint`;
  `make gtk-build/gtk-run/gtk-lint/gtk-build-linux`; the `gtk-build`/`e2e-gtk` CI legs; the CI
  `deb` leg + `build-deb.sh` + `nfpm.yaml`; `tools/shedtest` `--target gtk` (see M4 checklist);
  `Dockerfile.linux` (GTK-heavy, but ALSO used by `core-linux` — keep, slim); any `tools/shed/*.sh`
  GTK VM scripts; docs/plans references.

## Sub-milestones (green per commit)

### M1 — Tauri Linux `.deb` build (nfpm) + retarget shedctl + fix the CI `deb` leg

Produce a `shed-desktop` `.deb` built from the **Tauri** binary via the existing nfpm path, and
keep the CI `deb` leg green on the same commit.

**Files:** `linux/scripts/build-deb.sh`, `packaging/nfpm.yaml`, `packaging/shed-desktop.desktop`,
`linux/scripts/validate-deb.sh`, `linux/scripts/deb_identify_check.py`, `core/shedctl/src/main.rs`,
`Makefile` (`deb`/`deb-validate`), `.github/workflows/ci.yml` (the `deb` leg), possibly a new
`Dockerfile.deb`.

- **`build-deb.sh` — dual target-dir (all 3 reviewers, HIGH):** resolve the Tauri and core target
  dirs *independently*, correct whether `CARGO_TARGET_DIR` is set (Docker) or unset (local/release):
  - core/shedctl: `CORE_TARGET="${CARGO_TARGET_DIR:+${CARGO_TARGET_DIR}/core}"` else
    `${REPO_ROOT}/core/target`; `( cd core && cargo build --release --locked -p shedctl )`.
  - Tauri: `TAURI_TARGET="${CARGO_TARGET_DIR:+${CARGO_TARGET_DIR}/tauri}"` else
    `${REPO_ROOT}/tauri/src-tauri/target`; `( cd tauri/src-tauri && cargo build --release --locked )`
    (with the per-crate `CARGO_TARGET_DIR` exported for that sub-invocation). Using distinct
    `…/core` and `…/tauri` subdirs under a shared `CARGO_TARGET_DIR` avoids one workspace clobbering
    the other's `.rustc_info`/lockfile assumptions.
  - Stage `${TAURI_TARGET}/release/shed-desktop-tauri` → `dist/shed-desktop`;
    `${CORE_TARGET}/release/shedctl` → `dist/shedctl`.
- **Frontend build contract in one place (Codex):** `build-deb.sh` runs `npm --prefix tauri/ui run
  build` to produce `tauri/ui/dist` (required — plain `cargo build` skips `beforeBuildCommand`);
  callers (`make deb`, CI `deb`, release `linux`) must have run `npm ci` first. Document this in
  the script header.
- **Env rename:** `SHED_GTK_VERSION`/`SHED_GTK_ARCH` → `SHED_DEB_VERSION`/`SHED_DEB_ARCH`, updating
  BOTH `build-deb.sh:35-36` AND the `${…}` interpolations in `nfpm.yaml:9,11` in lockstep.
- **`nfpm.yaml`:**
  - `depends:` → the Tauri runtime deps (above), **with version floors** matching the Ubuntu 24.04
    baseline (mirror the GTK deb's `(>= …)` style): `libwebkit2gtk-4.1-0 (>= 2.44)`,
    `libgtk-3-0 (>= 3.24)`, `libayatana-appindicator3-1`, `librsvg2-2`, `libsoup-3.0-0`, `libc6`.
  - `recommends:` the polkit runtime package that provides `/usr/bin/pkcheck` on Ubuntu 24.04
    (verify the name — `polkitd` on 24.04). Recommends (not Depends): the app launches + fails-closed
    without it, so it must not block install on a headless box.
  - Add the polkit policy to `contents:` with `mode: 0644`:
    `./packaging/polkit/ai.stridelabs.shed-desktop.policy` →
    `/usr/share/polkit-1/actions/ai.stridelabs.shed-desktop.policy`. Confirm the action-id matches
    `approval.rs` (it does: `ai.stridelabs.shed-desktop.approve-credential`).
  - **Notifier icon (Codex):** verify the notifier's app-icon string; if it is
    `ai.stridelabs.shed-desktop`, install an icon alias under that name (or change the notifier
    string to `shed-desktop`) so the banner icon resolves. Keep the existing `shed-desktop.png`
    hicolor installs for the launcher.
  - Update the `description` (drop "GTK4/libadwaita" → the Tauri/WebKitGTK client).
- **`.desktop` — WM class (CONTRADICTION → verify in M2):** update the `Comment` (drop "GTK") now.
  `StartupWMClass` + the installed `.desktop` **basename** (`ai.stridelabs.ShedDesktop.desktop`)
  currently reflect the GTK app's class. Kimi says keep them; CodeRabbit + Codex say Tauri's Linux
  WM class differs. This is NOT statically provable (no `set_application_id` in the Tauri src) —
  **M2 verifies the real `WM_CLASS` via `xprop` on the VM**, then M1's `.desktop` is aligned
  (basename + `StartupWMClass` + nfpm `dst`). Until then, leave the GTK values and treat alignment
  as an M2 follow-through into the M1 commit (or a small M2 fixup commit).
- **`shedctl` retarget (Codex, required for a drivable shipped CLI):** change
  `core/shedctl/src/main.rs` `resolve_socket`/`default_socket_path` to default to `shed-tauri.sock`
  (flat, per `env.rs:94`) and read `SHED_TAURI_SOCKET`; optionally accept the old `SHED_GTK_SOCKET`
  as a transition fallback. Update the shedctl unit test + doc-comments. (This is Linux `.deb`
  tooling for the shipped client — in scope; `shed-core`/`shed-app`/`shed-core-ffi` untouched.)
- **`deb-validate` retarget:** parametrize `deb_identify_check.py` (one file, env-selected target —
  avoid a fork) to use `SHED_TAURI_*` env, the `shed-tauri.sock` layout, the WebKitGTK headless env
  (`WEBKIT_DISABLE_DMABUF_RENDERER=1` + `WEBKIT_DISABLE_COMPOSITING_MODE=1` + `LIBGL_ALWAYS_SOFTWARE=1`
  + `GDK_BACKEND=x11`) under Xvfb, and assert `platform=="tauri"`, `core=="rust"`. Then extend
  `validate-deb.sh` to ALSO: (a) `test -f /usr/share/polkit-1/actions/ai.stridelabs.shed-desktop.policy`;
  (b) run the installed `/usr/bin/shedctl identify` against the running app's default socket and
  assert it answers (proves the bundled CLI is not broken). The validate container may need the
  render-gate sandbox allowances (`--cap-add SYS_ADMIN`, `--security-opt seccomp=unconfined`,
  `--shm-size`) or an explicit WebKit-sandbox-disable env for the web-process to boot under Xvfb.
- **Docker image for `make deb` (Kimi + Codex):** DECISION — reuse the render image
  (`Dockerfile.tauri-linux`, which has the webkit build deps) + install `nfpm`, mirroring
  `tauri-build-linux`'s pattern (build `tauri/ui/dist` on the HOST first, `tar` the source into a
  writable `/work` so Tauri's `build.rs` gen/ writes don't hit a read-only mount, build to a
  `/target` volume). This avoids root-owned generated files in the repo and needs no Node in the
  image. Pin `nfpm` the same way release does (not the GoReleaser apt repo) if practical.
- **CI `deb` leg (all 3, must be in THIS commit):** in `.github/workflows/ci.yml` swap the `deb`
  job's `libgtk-4-dev libadwaita-1-dev` install for the Tauri build deps
  (`libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev librsvg2-dev libayatana-appindicator3-dev
  pkg-config build-essential`) + add `actions/setup-node` + `cd tauri/ui && npm ci`; and add
  `|| needs.changes.outputs.tauri == 'true'` to its `if:` so a `tauri/**`-only change rebuilds the
  shipped `.deb`.
- **Acceptance (M1):** `make deb-validate` builds `shed-desktop_<ver>_<arch>.deb` from Tauri and
  install-validates it in a clean `ubuntu:24.04`: the installed `/usr/bin/shed-desktop` launches
  with ONLY the declared `depends:`, answers `identify` → `platform=tauri`/`core=rust`; the polkit
  policy file is present; `/usr/bin/shedctl identify` answers. The CI `deb` leg is green on the
  commit. **release.yml is NOT touched yet.**

### M2 — Prove the Tauri Linux client is a viable GTK replacement (shed VM) — HARD GATE before M4

Run the Tauri client on real WebKitGTK in a shed VM via the `shedtest-linux` skill (computer-use
can't screenshot the VM). This is primarily verification (may need no code beyond the M2 fixup);
any real gap it surfaces is fixed here.

- **Probe (pass condition = green `--target tauri` shedtest in the VM + explicit op checks):**
  `identify` (platform=tauri), `sheds.list` + lifecycle (start/stop/reset/delete), create-SSE,
  `dashboard.dump` + `ui.current_pane`, `tray.dump` (the 4 native-menu ids), single-instance
  handoff (`app.activate`), `app.screenshot` (scrot) → capture a screenshot artifact.
- **WM_CLASS verification (resolves the M1 contradiction):** `xprop WM_CLASS` on the running
  window → set `.desktop` `StartupWMClass` + the installed basename + nfpm `dst` accordingly (fold
  the correction back into M1's files as an M2 commit if it differs from the GTK value).
- **Parity statement:** confirm feature parity with what the GTK `.deb` shipped (lifecycle +
  create + drivability); approvals/agents are a bonus GTK never had. Record the result in the plan.
- **Acceptance (M2):** the VM run is green on the probes above, the screenshot artifact is captured,
  and `WM_CLASS` is confirmed. Maintainer sign-off here is the gate that unblocks M4.

### M3 — Rewire the release pipeline (Linux = Tauri `.deb`) + make it release-ready, triggers nothing on merge

**Files:** `.github/workflows/release.yml` (the `linux` job + the `create-release` version-gate),
`scripts/release/update-version.sh`.

- **release.yml `linux` job** (Codex P0 #1): swap build deps `libgtk-4-dev libadwaita-1-dev` → the
  Tauri build deps (as CI `deb`); add `actions/setup-node@v4` + `cd tauri/ui && npm ci && npm run
  build` before `build-deb.sh` (a tag checkout has no `tauri/ui/dist` — it's gitignored — and
  `build-deb.sh` fails fast without it). Keep the `amd64`/`arm64` matrix, native-arch build, `nfpm`
  install, the arch assertion, and `gh release upload out/*.deb`.
- **Release-time validate (Codex + CodeRabbit, closes the arm64 gap):** run `validate-deb.sh` on
  the freshly built `.deb` before upload, on BOTH matrix arches (CI only validates amd64; the
  release runner is where arm64 dep skew is caught). Docker is available on the ubuntu runners.
- **update-version.sh + version-gate (Codex P0 #2 — REQUIRED for "pipeline ready"):** M1's
  `build-deb.sh` builds the Tauri workspace with `--locked`. `tauri/src-tauri/Cargo.lock` pins
  `shed-core`/`shed-app` at the workspace version, but `update-version.sh` bumps only `core/` — so a
  future release bump leaves the Tauri lock stale and `cargo build --locked` fails (reproduced by
  Codex). Fix `update-version.sh` to ALSO bump `tauri/src-tauri/Cargo.toml` (`[package].version`) +
  `tauri/src-tauri/tauri.conf.json` (`version`) and regenerate `tauri/src-tauri/Cargo.lock` (refresh
  the `shed-core`/`shed-app` entries — `cargo update -p shed-core -p shed-app --offline` or a
  `--locked`-safe regen). Extend the `create-release` version-gate to assert
  `tag == VERSION == core/Cargo.toml == tauri/src-tauri/Cargo.toml`. (This is release-only plumbing
  — it fires on a tag, not on merge — and is exactly what "leave the pipeline ready" requires.)
- `dispatch-apt-charliek` unchanged — same package name `shed-desktop` → drop-in apt upgrade.
  Confirm `charliek/apt-charliek/packages.yaml` still names `shed-desktop` (it does; the source is
  the Release asset, path-independent). Coordinate only if the name changed (it doesn't).
- Config only fires on a future `v*.*.*` **tag**; merging to `main` triggers NOTHING.
- **Acceptance (M3):** `actionlint`-clean; the `linux` job builds+validates the Tauri `.deb` on
  both arches and uploads; a dry-run of `update-version.sh X.Y.Z` (on a throwaway checkout, NOT
  committed) bumps all four manifests and leaves `cargo build --locked` green in BOTH workspaces;
  no version bump or tag is committed by this effort.

### M4 — Remove `shed-gtk` (two commits)

Split for a smaller blast radius (Kimi). **Blocked on M2 sign-off.**

**M4a — delete the crate:**
- Delete `core/shed-gtk/`; drop it from `members` in `core/Cargo.toml`; drop `--exclude shed-gtk`
  from `make core-lint` (→ plain `--workspace`); delete `make gtk-build/gtk-run/gtk-lint/
  gtk-build-linux`. Regenerate `core/Cargo.lock` (GTK/libadwaita crates disappear from the lock).
  Slim `Dockerfile.linux` (drop `libgtk-4-dev libadwaita-1-dev`; it stays for `core-linux`).
- Acceptance: `make core-test` + `make core-lint` green; `cargo metadata` shows no `shed-gtk`;
  the lock has no gtk4/libadwaita.

**M4b — delete the CI legs + harness + VM scripts:**
- CI: delete the `gtk-build` + `e2e-gtk` jobs; remove them from `ci-success`'s `needs:` AND the
  result-scan string (load-bearing — a dangling `needs:` to a deleted job errors the workflow). No
  `changes.outputs` filter edits are needed (filters are shared). The `deb` leg is now the sole
  Linux-`.deb` gate (its trigger fix landed in M1).
- Harness (full checklist — `rg -n 'gtk|GTK|SHED_GTK' tools/shedtest/` must return only
  historical/comment hits after): delete `tools/shedtest/test_gtk.py` — but FIRST **migrate
  `test_second_launch_hands_off` (single-instance flock) into `test_tauri.py`** (Tauri also uses an
  `fs2` flock; the handoff test must not be lost). Remove `GtkClient` (`client.py`), `_SUBPROC["gtk"]`
  + `BIN`/`gtk_launch_env` (`ui.py`), the `gtk` fixture (`conftest.py`), the `_reset_mock`
  `("gtk","tauri")` branch → `"tauri"` (`conftest.py`), `"gtk"` from `_BACKEND_TARGETS` (`_marks.py`),
  the `gtk` branch of `TARGETS`/`--target` (→ `("mac","tauri")`), `SHED_GTK_TEST_TIMEOUT_SCALE`, and
  the `gtk`-specific branches/comments in `test_shared.py` + `dashboard_rows` normalization in
  `client.py`. Decide `@needs_backend`: keep (harmless — both remaining targets implement backend)
  or drop; state which.
- `Makefile`: delete the `e2e-gtk` target.
- Any `tools/shed/*.sh` GTK VM scripts: remove or retarget to `--target tauri`.
- Acceptance: mac e2e (`make e2e-tauri`... note: mac Swift e2e via the `swift` leg), `make e2e-tauri`,
  `make tauri-test-linux` + `make tauri-build-linux`, and `make deb-validate` all green; the `rg`
  surface is clean; `ci-success` green with the two legs gone.

### M5 — Docs + convention sweep

**Files (exact):** `CLAUDE.md` (the "GTK/Linux client (`shed-gtk`)" section → "Linux = the Tauri
`.deb`"; the architecture bullets; the change-loop targets; the "What's built" GTK framing),
`RELEASING.md` (the Linux bullet: built from Tauri, WebKitGTK runtime, release-time validate),
`docs/roadmap.md`, `docs/reference/architecture.md` (if it names `shed-gtk`), the `Makefile` `help`
text (auto-updates as targets are deleted), `packaging/nfpm.yaml` description (done M1), and the
plans (`plans/phase-2-rust-clients.md`, `plans/phase-3-enhancements.md`,
`plans/phase-4-rust-core-only.md`, `plans/tauri-phase-c.md`) to reflect "Linux = Tauri `.deb`; GTK
retired." Note the Tauri-Linux packaging + WebKitGTK runtime deps. **Do NOT bump the version or
change release triggers.**
- Acceptance: `rg -n 'shed-gtk'` across tracked files returns only intentional historical
  references (changelog/plan archives), not live instructions; `make docs` builds.

### M6 — Merge `feat/rust-core` → `main`

Open the PR (`gh pr create --body-file`, never a heredoc with backticks — it executes them). Run
`/git-commands:watch-pr` — fix any CI/bot findings, re-watch. Merge green (authorized). **STOP** —
hand back to the maintainer; do NOT bump the version, tag, or release.

## Gates (all green before each commit)

`source ~/.cargo/env` first; always `cd /Users/charliek/projects/shed-desktop` before `make`
(cwd-drift silently no-ops a bare `make`); prefix background `make` jobs with `source ~/.cargo/env`.

- `make core-test` · `make e2e-tauri` (mac) · `make tauri-test` · `make tauri-test-linux` +
  `make tauri-build-linux` (the WebKitGTK render gate — MANDATORY for any shared/Linux change) ·
  `make deb-validate` (the new Tauri `.deb`).
- While `shed-gtk` still exists (through M3), keep its gates green too (the CI `gtk-build`/`e2e-gtk`
  legs; `make gtk-build` where no display is needed).
- Drivability must stay green (the North Star: every surface drivable + observable over IPC).

## Guardrails

- Swift mac app stays the macOS artifact — do NOT modify `Sources/` or the mac DMG/Sparkle path.
- Keep `shed-core`/`shed-app`/`shed-core-ffi` intact. `shedctl` is retargeted (default socket →
  Tauri) but stays — it is the `.deb`'s headless driver. Only `shed-gtk` is removed.
- Land + PROVE the Tauri `.deb` (M1–M3) and get M2 sign-off BEFORE deleting GTK (M4).
- The `.deb` package name stays `shed-desktop` (drop-in apt upgrade); no `conflicts`/`replaces`
  needed for an in-place upgrade.
- Do NOT cut a release — no version bump, no tag, no publish; leave the pipeline ready, merge to
  `main`, then hand back.

## Risks / watch-items (folded from the panel)

- **Two cargo target dirs** (all 3): resolved in M1 via independent `…/tauri` + `…/core` dirs;
  `--locked` both.
- **Runtime dep correctness** (all 3): `deb-validate` in a clean container is the proof — if launch
  fails, a dep is missing (add + re-validate). Do not add `libssl`/`libxdo` mechanically.
- **CI `deb` leg** (all 3): deps + Node/`npm ci` + `tauri` filter must land in the M1 commit or the
  leg reds.
- **`.desktop` WM class** (contradiction): verified empirically in M2, not guessed.
- **shedctl default socket** (Codex): retargeted to Tauri in M1 or the bundled CLI can't drive the
  shipped app.
- **polkit runtime dep** (Codex): `pkcheck` absence isn't caught by `identify` (fails closed) →
  `recommends: polkitd`; the app still launches without it.
- **Notifier icon name** (Codex): verify + install an alias or align the string, else banners show
  no icon.
- **Tauri manifests at `0.0.1` → release-breaking with `--locked`** (Codex P0 #2, now M3-in-scope):
  M1 builds the Tauri workspace `--locked`; `tauri/src-tauri/Cargo.lock` pins `shed-core`/`shed-app`
  at the workspace version, but `update-version.sh` bumps only `core/`. A release bump therefore
  leaves the Tauri lock stale → `cargo build --locked` fails (reproduced). This is NOT cosmetic:
  "leave the pipeline ready" requires M3 to teach `update-version.sh` to bump the Tauri manifests +
  regenerate the Tauri lock, and to extend the version-gate. (The `.deb` *package* version is
  env-driven and unaffected; the failure is the build itself.)
- **arm64 `.deb` validation** (CodeRabbit + Codex): closed by the M3 release-time `validate-deb.sh`
  on both arches.
- **Docker root-owned generated files** (Codex): the `make deb` container copies source into a
  writable `/work` (mirrors `tauri-build-linux`).
- **postinst icon-cache/desktop-database** (CodeRabbit, LOW): GTK shipped the same gap; optional
  polish (`update-desktop-database`/`gtk-update-icon-cache` in an nfpm `scripts.postinstall`) — note,
  defer unless trivial.
- **`ci-success` needs-list edit** (M4b): remove deleted jobs from BOTH `needs:` and the result
  scan.
