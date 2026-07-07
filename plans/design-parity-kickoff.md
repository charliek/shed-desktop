# Kickoff prompt — Tauri ↔ Swift design-parity hardening (new Claude-app session, needs computer-use)

Paste the block below into a fresh Claude Code session **in the Claude app** (it has computer-use for
screenshots). It's self-contained.

---

Plan and then autonomously execute a **design-parity hardening pass** on the shed-desktop **Tauri** client so
it visually matches the **Swift macOS app** (the reference). This is a stand-alone effort off the just-merged
`feat/rust-core` (Batch 3 landed via PR #30, merge commit `4fce382`). Use computer-use to screenshot-compare
the two apps in detail — that side-by-side comparison IS the discovery, and re-screenshotting after each
change is the visual equivalent of the drivability check. Follow the exact plan→panel→build→review→ship
workflow below.

**Mission.** The maintainer ran the Tauri app and found it *functional but visually off* vs the Swift app. Tune
it to parity. Confirmed starting gaps (verify + expand via your own computer-use audit — don't assume):
- **Menu-bar popover (B1b):** the **tray icon is much too small / wrong** — `tauri/src-tauri/src/tray.rs` sets
  the tray to `app.default_window_icon()` (the full app icon), NOT a macOS menu-bar **template** image; it
  likely needs a monochrome ~18px template asset + `TrayIconBuilder::icon_as_template(true)`. The popover's
  **hover/mouse-over colors are off** — `TrayPopover.tsx` uses `.hlink` (a subtle gray, `--shed-surface-hover`)
  where the Swift `MenuBarContentView` `MenuActionRow` uses the vivid native `controlAccentColor` blue +
  `alternateSelectedControlTextColor`. The popover **window is a fixed 320×460**, leaving dead space below the
  footer — consider content-sizing (a JS→Rust resize protocol) or a tighter/dynamic height. Overall
  formatting/spacing/dividers need pixel-tuning vs `MenuBarContentView`.
- **Main dashboard UI (pre-existing, Phase A — fold in):** icons + colors are off, **especially the shed/agent
  control buttons** (play/terminal/reset/stop/delete in the shed cards — washed-out tinted backgrounds). Audit
  the whole app: every pane's colors, icon sizes/weights, button styles, corner radii, spacing, hover/active
  states, and the font stack — vs the Swift counterparts.

**Read first.** `CLAUDE.md` (the North Star: every surface drivable + observable over IPC — design changes must
NOT break that). `plans/tauri-phase-c.md` (§8 decisions; the B1b popover in §3.7). The memories
`tauri-client-state.md` + `review-process.md`. Parity targets — the Swift views in
`Sources/ShedDesktopUI/` (`MenuBarContentView.swift`, the Sheds/Approvals/Agents/Activity/System pane views,
the shared components + the `Theme`) and how `Sources/ShedDesktopApp/AppModel.swift` (~:641-701) sets the
`NSStatusItem` template image. The Tauri side to change — `tauri/ui/src/` (`App.tsx`, `TrayPopover.tsx`,
`index.css` [the `--shed-*` oklch tokens, "ported from the Design MCP / `core/theme.css`"], `lib/`),
`tauri/src-tauri/src/tray.rs`, and `packaging/icon/` (icon assets; regenerate via
`packaging/icon/regenerate.sh`).

**The two apps — run BOTH for apples-to-apples comparison.**
- Swift mac app (the read-only reference): `make run` → `build/ShedDesktop.app`; drive/observe via
  `build/ShedDesktop.app/Contents/Resources/bin/shedctl` (`ui show-window`, `screenshot`).
- Tauri app: `source ~/.cargo/env && make tauri-run` (production build; launches menu-bar-first — click the
  tray icon for the popover).
- Both speak the same JSON IPC — drive each to the SAME pane/state before comparing. NOTE: an app launched from
  a Bash tool can get killed on session churn; if you need them to persist, ask the maintainer to launch them
  in their own terminal, then screenshot.

**Computer-use.** `request_access` for the apps (native apps = full tier: screenshot + click OK; the terminal
is click-tier → use the **Bash tool** for shell commands; a browser is read-tier). Screenshot the desktop with
both windows, navigate each pane in both, and extract concrete deltas: exact colors (sample hex/oklch), padding
/margins, icon px sizes, corner radii, hover/active states, the tray-icon size + rendering, fonts/weights.
Build a per-surface gap list. **Caveat:** prior sessions hit a macOS Screen-Recording/Accessibility TCC block
on computer-use screenshots (the capture runs outside the granted app bundle) — if `request_access`/`screenshot`
fails, ask the maintainer to grant it or to capture + attach, or fall back to the app's own `screenshot` IPC op.

**Workflow — follow exactly (same as the prior batch).**
- **Phase 1 — PLAN, then PANEL.** Do the computer-use discovery FIRST (screenshot + gap-list both apps).
  Settle each fix's design. Use `AskUserQuestion` ONLY for genuine maintainer calls (e.g. an ambiguous exact
  value, or "content-size the popover vs a fixed height", or "match the native accent-blue menu highlight vs a
  softer custom hover"). Decompose into green-per-commit sub-milestones (suggested: tray-icon → popover polish
  → main-UI control buttons → a token/usage audit → dark-theme pass). Fold the design + decomposition into a
  new `plans/tauri-design-parity.md`. Then run `/planning:ask-panel` (Codex + Kimi K2.6 + CodeRabbit), synthesize,
  and fold the load-bearing findings before writing code. Flag contradictions for the maintainer.
- **Phase 2 — BUILD each sub-milestone, in this order every time:** implement → `/simplify` (the 4-agent cleanup
  pass; apply the fixes) → **adversarial review** — external (`/cursor:review` and/or `codex`) AND an internal
  general-purpose reviewer, cross-checked per `review-process` (set a `ScheduleWakeup`//loop poll ~300–600s when
  an external review runs in the background so a flaky/no-notify review can't stall the run) → fold every real
  finding → **RE-SCREENSHOT via computer-use to confirm the gap closed** → gates → commit green (one focused
  commit per sub-milestone).
- **Phase 3 — SHIP:** open a PR onto `feat/rust-core` (`gh pr create --body-file`, never `$(cat <<EOF…backticks…)`).
  Run `/git-commands:watch-pr` — fix any CI/bot findings, re-watch. Merge green.

**Gates (all green before each commit).** `source ~/.cargo/env` first. `make e2e-tauri` (mac) · `make tauri-test`
· `make core-test` · and for ANY shared/Linux change (CSS is shared): `make tauri-test-linux` + `make
tauri-build-linux` — the **WebKitGTK render gate**; oklch/color-mix CSS changes MUST pass it (the render smoke
IS the CSS gate — a static denylist would miscalibrate). Always `cd /abs/path` before `make` (cwd-drift silently
no-ops a bare make from a subdir). The **drivability must stay green** — `tray.dump`/`current_pane`/the e2e
suite must still pass; a visual change must not break the harness (e.g. keep the `data-*`/reporting hooks).

**Guardrails.** The Swift mac app is the **read-only reference** — do NOT modify `Sources/`. Scope = design only:
CSS/tokens/icon-assets/layout/component-styling — no new features, no changes to the drivability spine or IPC
ops. Tune **both** light and `data-mode="dark"` themes if you touch tokens. Keep it macOS-focused but the render
gate (Linux WebKitGTK) must stay green for any shared CSS. New tray/app icons regenerate via
`packaging/icon/regenerate.sh`. cargo lives at `~/.cargo/bin` (`source ~/.cargo/env`).

**Start by** running both apps + doing the computer-use screenshot comparison to build the gap list, then
propose the sub-milestone decomposition + the design decisions that need my input BEFORE you fold + `/planning:ask-panel`.
