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

## CI & build

- [ ] **shed-core Linux CI on both arches.** M1 is proven on aarch64 (Docker + a
  shed); add an `x86_64-unknown-linux-gnu` CI leg so both are covered.
- [ ] **CI path-filter (`changes`) job** so the Linux/GTK/Xvfb jobs skip Mac-only
  and docs-only PRs (mirror roost's `changes` job) — keeps Mac PR feedback fast.
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

## macOS dev QoL

- [ ] **Run the GTK app on macOS natively** (Homebrew `gtk4` + `libadwaita`) for
  quick cross-platform UI eyeballing from a Mac. Nice-to-have; the primary run
  target stays Linux (a shed), so this is convenience, not a gate.

## Docs hygiene

- [ ] **Fix stale references** (scheduled in Phase 2 M5; tracked here so they're not
  lost): `docs/reference/architecture.md` still says the Rust flag is off by
  default; `docs/reference/rust-core.md` still labels approvals "Phase 2" / GTK
  "Phase 3".
- [ ] **Tighten a count**: "64 pytest fns / 37 IPC ops" (the two are sometimes
  conflated as "64 ops").
