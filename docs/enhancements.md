# Known enhancements & QoL follow-ups

A running backlog of smaller improvements and quality-of-life items — things not
big enough to be roadmap *directions* but worth not losing. Add to it whenever you
defer something with "we should do X later." Linked from [the roadmap](roadmap.md).

Check items off (or strike them) as they land.

## Rust core & Swift/Rust parity

- [ ] **Unify config discovery.** Once the Rust `shed-core` `config` module lands
  (Phase 2 M2), retire the Swift `ShedConfig` parser so `~/.shed/config.yaml` has a
  single parser, not two. (Keep a cross-language parity test until then.)
- [ ] **Retire the Swift `URLSession` path** after the Rust core has shipped as the
  macOS default for ≥2 releases (Phase 2 M0 keeps `SHED_DESKTOP_RUST_CORE=0` as a
  rollback for that window).
- [ ] **Generalize the golden-JSON cross-backend diff** beyond M0's set to all
  backend-sensitive IPC payloads, as a standing parity guard.
- [ ] **Full pinned-HTTPS handshake integration test.** M1 added a verifier-level
  accept/reject test (`tls.rs`) + a redirect fail-closed test (`http.rs`) that run
  on Linux CI, alongside the existing non-https config-error test — covering the
  pin *decision* and the redirect policy. A true end-to-end pinned-TLS *handshake*
  test (a local rustls server with a self-signed cert via `rcgen`, hit through a
  pinned `Client`) is deferred: heavier test infra for incremental assurance.

## CI & build

- [ ] **shed-core Linux CI on both arches.** M1 is proven on aarch64 (Docker + a
  shed); add an `x86_64-unknown-linux-gnu` CI leg so both are covered.
- [ ] **CI path-filter (`changes`) job** so the Linux/GTK/Xvfb jobs skip Mac-only
  and docs-only PRs (mirror roost's `changes` job) — keeps Mac PR feedback fast.
- [ ] **Release-bundle size gate in CI.** M0's CI step runs arm64 + cold-launch +
  the golden cross-backend byte-diff against the *debug* bundle (fast, per-PR);
  the release-size budget is enforced by `make m0-gates` (pre-ship). Fold a
  release-bundle size check into CI if the debug proxy proves too loose.
- [ ] **Snapshot-cache the GTK test box.** `tools/shed/shed-test.sh --snapshot-base`
  the `sd-gtk-dev` shed (and/or a CI image) so cold boots skip the provision hook.

## GTK / Linux client (post-MVP)

- [ ] **Native-Linux test skill.** Author a shed-desktop analog of roost's
  `popos-test` (run the GTK suite directly on a Linux box, no shed) — only the
  Mac→shed `shedtest-linux` skill exists today.
- [ ] **`.deb` release wiring.** Phase 2 M5 builds + install-validates the `.deb`;
  wire up actual shipping (apt repo / GitHub release asset) as a follow-up.
- [ ] **Ship a `shedctl`-equivalent CLI in the `.deb`** (roost ships both `roost`
  and `roostctl`) if a Linux CLI driver proves useful.
- [ ] **Single-instance flock for shed-gtk** (target M4): mirror roost's
  `single_instance::acquire` so a second launch activates the running window
  instead of unlinking its live socket. M2 defers this to the harness (which owns
  the process lifecycle) — see the comment in `shed-gtk/src/ipc.rs` `bind`.
- [ ] **Parallel multi-host `list_sheds`** in shed-gtk: `join_all` the per-host
  fetches. Sequential is fine at one host (M2); at 2+ hosts a slow/down host stalls
  the rest by up to shed-core's 8s per-request timeout.

## macOS dev QoL

- [x] **Run the GTK app on macOS natively** — DONE (2026-07-02, pulled into Phase 2
  M2): `shed-gtk` builds, runs, and screenshots on this Mac via Homebrew `gtk4` +
  `libadwaita` (`make gtk-run` / `make gtk-build`). `shed-gtk` is a workspace member
  but not a `default-member`, so the macOS app's `core-test`/`core-lint` stay
  GTK-free. Linux remains the shipped target; the Mac run is a dev/UI-comparison loop.

## Docs hygiene

- [x] **Fix stale references** — DONE (Phase 2 M5): `architecture.md` +
  `rust-core.md` now reflect the Rust core as the macOS default and the shipped
  `shed-gtk` GTK/Linux client (was: "flag off by default" / approvals "Phase 2" /
  GTK "Phase 3").
- [ ] **Tighten a count**: "64 pytest fns / 37 IPC ops" (the two are sometimes
  conflated as "64 ops").
