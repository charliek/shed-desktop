# Tauri ↔ Swift design-parity hardening — plan

**Status (pick-up point):** PLAN written, decisions locked, computer-use discovery DONE,
`/planning:ask-panel` DONE + folded (Kimi + CodeRabbit converged; Codex rate-limited — see the
Panel-fold section). Next: build M1. Branch `tauri-design-parity` off
`feat/rust-core` (`4fce382`, PR #30). One PR onto `feat/rust-core`, one green-per-commit
sub-milestone each — same flow as Batch-2/3 (implement → `/simplify` → adversarial review
[external `/cursor:review`/codex + internal general-purpose, cross-checked per
[[review-process]]; `ScheduleWakeup`//loop poll ~300–600s when a background review runs] →
fold → **RE-SCREENSHOT via computer-use** → full gates → commit green).

## Mission

The Tauri client is functional but visually off vs the **Swift macOS app** (the read-only
reference). Tune it to parity. Scope = **design only** — CSS/tokens/icon-assets/layout/
component-styling. NO new features, NO changes to the drivability spine / IPC ops. Tune
**both** light and `data-mode="dark"`. Keep macOS-focused but the **Linux WebKitGTK render
gate** must stay green for any shared CSS.

## Discovery (computer-use, both apps side-by-side — confirmed)

Native screenshots of BOTH apps + full source read. Key finding: the Tauri dashboard is a
port of a **separate, more SPACIOUS "Design MCP mockup"**, not a dense port of the Swift app.
Palette **tokens are already aligned** (Swift `Theme.swift` sRGB hex ≈ Tauri `--shed-*` oklch),
so the gaps are **sizing/tinting/icons**, not hue. Confirmed deltas:

- **Tray icon** — Swift uses an SF Symbol (`shippingbox.fill`) → an auto **template image**
  (monochrome, ~18px, adapts to the menu bar) + a `" N"` running-count title. Tauri uses
  `app.default_window_icon()` = the **full colored app icon** → oversized + colored. CONFIRMED.
- **Popover control buttons / dead space** — the popover window is a fixed **320×460** and
  leaves ~half its height EMPTY below the footer (screenshot-confirmed). Footer rows have **no
  icons** and a plain-gray `.hlink` hover; Swift `MenuActionRow` has a **leading SF-symbol
  icon** + a **vivid accent-blue fill** hover. CONFIRMED.
- **Dashboard control buttons ("washed-out")** — Tauri `IconBtn` tints with
  `color-mix(in oklch, intent 13%, var(--shed-inset))`; `--shed-inset` is a warm BEIGE, so
  mixing only 13% intent muddies EVERY tint toward tan (the terminal "accent" button reads tan,
  not blue — screenshot-confirmed). Swift `IntentButton` = `intent.opacity(0.12)` over the
  WHITE card surface → clean vivid pale tints. Also oversized: 42×34 vs Swift 26×26.
- **Density** — Tauri shed name 19px bold / card `py-18` / 232px sidebar / filled accent
  "New shed"; Swift 14px semibold / `py-12` / 200px sidebar / a plain text+icon accent link.

## Maintainer decisions (2026-07-06, locked via AskUserQuestion)

1. **Dashboard scope = FULL DENSE PARITY.** Rescale the whole dashboard down to the Swift
   app's metrics (14px names, 26px buttons, `py-12` cards, 200px sidebar, text-link header
   actions). Not just targeted polish — match Swift.
2. **Popover height = CONTENT-SIZE IT.** Add a small JS→Rust resize protocol (ResizeObserver
   measures the DOM → `invoke` → `window.set_size`) so the popover hugs its content like Swift
   and adapts as approvals/sheds counts change.
3. **Popover/menu hover = BRAND ACCENT-BLUE FILL.** Hovered footer/menu row fills with the
   app's own `--shed-accent` + `--shed-accent-fg` text + a leading icon. Matches Swift's vivid
   look AND stays portable (the popover CSS is shared with the Linux/GTK build — no
   `controlAccentColor` there).

## ⚠️ Panel fold (2026-07-06 — Kimi K2.6 + CodeRabbit converged; Codex was rate-limited).
Load-bearing corrections — these SUPERSEDE the milestone sketches below where they conflict.

- **[BLOCKING · CR C1] The popover is built `resizable(false)` (`lib.rs:710`) → `set_size` may
  be silently ignored on a borderless NSWindow.** M2 MUST build/flip the popover
  `resizable(true)` (keep borderless / `always_on_top` / `skip_taskbar` — no visible resize
  handles, still not user-draggable). De-risk with a 10-line spike (set a height, read it back)
  BEFORE wiring the JS protocol.
- **[BLOCKING · CR H1 + Kimi] The resize needs a DRIVABLE assertion (North Star).** Add the
  popover window's `inner_size().height` to the `tray.dump` popover block (additive — read via
  `get_webview_window(POPOVER_ID)`; not an op-signature change). Add a `test_tauri.py` assertion
  that (a) `tray.dump` popover `running_sheds`/`pending_approvals` stay COMPLETE after
  `tray.show` (nothing clipped), and (b) the reported height DIFFERS between empty-approvals and
  populated-approvals state. This is the only way M2 satisfies "green per commit."
- **[BLOCKING · CR H2 + Kimi] `resize_popover` is a mac-only APP COMMAND — gate the handler
  registration too.** Both the `#[command] fn resize_popover` AND its entry in the
  `generate_handler!` list (`lib.rs`) must be `#[cfg(target_os = "macos")]`, or `tauri-test-linux`
  / `tauri-build-linux` fail to compile. App commands are NOT per-window ACL-scoped, so
  `capabilities/popover.json` needs NO new entry (its comment already says this) — instead the fn
  itself must **no-op unless `window.label() == POPOVER_ID`** (else `main` could call it).
- **[BLOCKING · CR H3 + Kimi] M1 template + `.title()` + `icon_as_template` are macOS-only —
  strictly `#[cfg(target_os="macos")]`.** Linux keeps `app.default_window_icon()` (a monochrome
  silhouette renders as a black blob on Linux trays; no template concept). Ungated calls break
  the Linux gate.
- **[HIGH · CR L-5 + Kimi] The tray template must be a GENUINE black-on-transparent glyph, NOT a
  `sips` downscale of the colored master.** Add a `generate-icon.swift --template` path (skip the
  rounded-square body fill, render the SF glyph in solid black on a CLEAR context) → emit
  `tauri/src-tauri/icons/tray-template.png` (18px) + `@2x` (36px). `tray.rs` loads it via
  `include_bytes!` + `Image::from_bytes` (compile-time embed → NO `tauri.conf.json` bundle entry
  needed; the file just has to exist in the source tree).
- **[HIGH · both] The intent-tint recipe must NOT mix with `transparent` (oklch hue-shift /
  dark-mode washout).** Use `bg: color-mix(in srgb, ${v} 14%, var(--shed-surface))` +
  `border: color-mix(in srgb, ${v} 34%, var(--shed-border))` — `srgb` matches Swift's
  `opacity()` alpha-compositing, and mixing into the per-mode `--shed-surface`/`--shed-border`
  tokens (not `transparent`) keeps the border visible in BOTH modes. M5 verifies dark; if it
  still washes out, promote to per-mode `--shed-<intent>-tint`/`-tint-border` tokens in
  `index.css` (mirroring how `Theme.swift` authors both modes).
- **[HIGH · CR M-4] `data-pane` MUST survive the `max-w-[880px]` wrapper removal (`App.tsx:1101`)
  — it is the single highest-value hook** (the computed-style probe reads `[data-pane]`'s
  `--shed-accent`). Keep `data-pane={pane}` on whatever element replaces the wrapper.
- **[MED · both] Popover resize needs debounce + clamp** to avoid a measure→reflow→measure
  jitter loop: a `requestAnimationFrame`-debounced `ResizeObserver` measuring
  `document.documentElement.scrollHeight` (fixed width 320, clamp 120…640), invoking only when
  the height changed by >1px, measured AFTER the fetch cycle settles.
- **[MED · both] AC specificity.** M4 = an explicit per-pane checklist (Sheds · Approvals ·
  Agents · Activity · System · Preferences · Create), not "close to Swift." Each milestone's AC
  folds its mechanical invariant: `computed_style()` returns non-transparent `bg` + non-empty
  `accent`; `tray.dump` rows stay complete; all `data-*` hooks present.
- **[MED · both] `.menu-row` accent hover uses DIRECT tokens** (`--shed-accent` /
  `--shed-accent-fg`) — no new `color-mix` → can't regress the render gate. It's shared CSS, so
  M2 runs the Linux gates too.
- **[MED · Kimi] Gate selection.** `core-test` is irrelevant to these changes (no `shed-core`/
  `shed-app` edits) → DROP it from the per-commit gates; run it ONCE in M5 as belt-and-suspenders.
  Per-commit = `make tauri-test` · `make e2e-tauri` · (shared CSS →) `make tauri-test-linux` +
  `make tauri-build-linux`.
- **[LOW · Kimi] M5 dark verification is MANUAL** (computer-use: click the header moon toggle →
  re-screenshot) — the `mode` state is App-local, and adding a `ui.set_theme` op would violate the
  "no drivability changes" guardrail. State it as manual; don't add the op.
- **[LOW · CR M-3] `HeadAction` filled→link is drivability-safe** — no `data-*`/`report*` hook is
  attached; create/refresh are driven by IPC ops (`ui.show_create`/`sheds.refresh`), not clicks.

## Swift reference scale (the dense target — source of truth)

| Token | Swift value |
|---|---|
| Page title | `26 bold` (Theme.text) |
| Page subtitle | `12` textMuted |
| Section / host header (uppercase) | `11 semibold`, tracking 0.6, textMuted |
| Card primary name (shed/host/session) | `14 semibold` |
| Card meta line | `12` textSecondary |
| Badge / pill | `10 medium` (glyph `9 semibold`) |
| Header action ("New shed"/"Refresh"/"Reveal log") | **text+SF-icon link**, `13 medium` accent — NOT a filled button |
| Sidebar row | label `13` (selected `.medium`), icon `14` in an 18-wide frame; count pill `11 medium` |
| Sidebar | width **200**, H-padding 8, rows `px9 py8` gap3, selected fill `accentSubtle` r8 |
| IntentButton (control) | **26×26**, r7, glyph `12 medium`, bg `intent@0.12`, border `intent@0.30` 0.5, glyph = full intent |
| Approve / Deny | `13 medium`, pad `H14 V7`, r8, filled (approve / denyBg) |
| NamespaceIcon (approval) | `32×32`, r8, bg `color@0.18`, glyph = namespace color |
| RC StatePill | `11 medium`, width 84, `V4`, r6, bg `color@0.18` |
| Activity row | time `11 mono` (w66), badge, op `12`, result `12 medium`; row `V8`; within one card, `Divider`-separated |
| System metric | label `10` muted, value `12 mono`; metrics row spacing 16 |
| Card | radius **14**, fill surface, border 0.5, 2-layer soft shadow; row pad `H14 V12`, box pad `14` |
| StatusDot | 8px |
| App header | shippingbox icon + "shed desktop" `13 medium` textSecondary; right: pending Label `12 medium` danger + 7px dot + `12`; pad `H16 V11`; bg `Theme.bg` |
| Page content | left-aligned, H-padding 20 (no 880 max-width centering); card-list spacing 10; host-group spacing 16 |

## Sub-milestones (green per commit)

### M1 — Tray icon (template + running count) — DONE (verified on screen)
`tray.rs` + a new monochrome template asset. On macOS, replace `app.default_window_icon()` with
`Image::from_bytes(include_bytes!("../icons/tray-template@2x.png"))` (a 36px **black-on-transparent
shippingbox silhouette**) + `TrayIconBuilder::icon_as_template(true)` (strictly `#[cfg(macos)]`),
so the status item auto-tints for the light/dark menu bar and sizes to ~18pt (tray-icon-0.24
scales the NSImage to 18pt; the @2x source stays crisp on retina). Linux keeps the colored
window icon (a silhouette renders as a black blob on GTK trays). Asset via
`packaging/icon/regenerate.sh --template` (skips the rounded body, black glyph on a clear context)
→ `tauri/src-tauri/icons/tray-template.png` (18px) + `@2x` (36px); embedded via `include_bytes!`
(no `tauri.conf.json` bundle entry needed). **Running-count title INCLUDED** (maintainer asked —
a helpful indicator + Swift parity): `tray::update_running_count(app, n)` sets the status item's
`set_title(" N")` (empty at 0), driven from `ui_report` — the dashboard (`main`) reports its full
shed list there even while hidden at launch, so the count is live WITHOUT a Rust-side poller.
macOS-only; a process-global cached count skips the native `set_title` on identical re-renders.
**AC:** `make tauri-run` → the mac menu-bar shows a crisp monochrome box (not the colored app
icon) + the running-shed count, matching the Swift status item. Drivability: no IPC-op change;
the `ui_report` count is a mac-only side-effect computed before the existing merge (spine
unchanged — the count is a native title, not observable via `tray.dump`, same as the icon).

### M2 — Popover parity — DONE (verified on screen)
Rounded corners + surface bg added mid-milestone (maintainer flagged them as a further gap):
- **Rounded 12px corners + shadow (Swift `NSPopover` parity).** The popover was a borderless
  OPAQUE rectangle (square corners). Fix: build it `transparent(true)` + `shadow(true)` and let
  the webview round its own corners (`rounded-[12px] overflow-hidden` on the root). `transparent`
  on macOS needs the `macos-private-api` tauri feature (unioned mac-only in `Cargo.toml`) — a
  private CoreAnimation API, fine for the DMG/Sparkle distribution (only App Store would care).
  The shared `body { background }` is nulled under the popover via `body:has([data-tray-popover])`
  (parses on WebKitGTK 2.44, never matches on the popover-less dashboard/Linux) so only the
  rounded card paints. `make tauri-build` uses plain `cargo build` (ignores the config feature
  list), so the feature is set in `Cargo.toml`, NOT via `macOSPrivateApi` in `tauri.conf.json`.
- **Native vibrancy material (maintainer decision, 2026-07-07).** After trying a flat
  `--shed-surface` card, the maintainer chose true native parity: the popover uses the macOS
  `Popover` vibrancy material (`EffectsBuilder::new().effect(Popover).state(Active).radius(12)`)
  — the real frosted, environment-tinted menu-bar surface, indistinguishable from the Swift
  `NSPopover`. `state(Active)` keeps the frost at full strength (the popover is a non-activating
  window, which otherwise renders the washed-out inactive state). The card paints NO background
  (transparent) so the material shows through; `radius(12)` rounds the material. mac-only — the
  Linux/GTK build has no popover. (The webview transparency + `body:has` rule from the rounding
  work is what lets the material show.)
- **Footer icons + accent hover.** `FooterRow` gets a leading lucide icon (Open dashboard →
  `AppWindow`/`SquareDashed`… use `AppWindow`; Preferences → `Settings`; Check for Updates →
  `ArrowDownCircle`; Quit → `Power`), glyph `~15`, frame-aligned. Replace `.hlink` with a
  hover style: `bg var(--shed-accent)` + text `var(--shed-accent-fg)` (icon inherits) on
  hover — a small `.menu-row` class in `index.css` (shared → rides the render gate). Disabled
  rows: no hover, `opacity-40`. Rows `px-2 py-1.5` r6, container `p-1.5` (Swift `MenuActionRow`
  H8 V6 r6, outer H6).
- **Content-size (resize protocol).** In `popover.tsx`/`TrayPopover.tsx`, a `ResizeObserver`
  (or measure `scrollHeight` after each render) → `invoke("resize_popover", {height})`; a new
  **mac-only** Tauri command `resize_popover` sets the `popover` window inner height to the
  measured content (clamped, e.g. 120…640) at the fixed 320 width. Guard: `#[cfg(target_os =
  "macos")]`, exposed only in `capabilities/popover.json`. Measure AFTER data settles (the
  `popover-refresh`/fetch cycle) so the height tracks approvals/sheds counts. Keeps the
  `data-tray-popover` hook + `reportTray` intact.
- **Neutral surface + weight.** Header "shed desktop" → `font-medium` (Swift `.medium`), not
  semibold. Consider the popover bg: Swift paints `windowBackgroundColor` (neutral); keep
  `--shed-bg` (linen) for brand consistency unless it reads wrong after the resize — decide on
  re-screenshot. Approvals block: Swift uses `red@0.08`; the Tauri `--shed-deny-bg` is heavier
  — soften to a `color-mix(var(--shed-danger) 8%, var(--shed-surface))` if it over-shouts.
- **AC:** `tray.show` → the popover hugs its content (no dead space), footer rows show icons +
  fill accent-blue on hover. `tray.dump` popover block unchanged (rows still reported).

### M3 — Dashboard control-button parity (`App.tsx`) — DONE (tint; sizing deferred to M4)
The headline "washed-out" gap was the TINT recipe, not the size — so M3 fixes the color and
M4's coherent rescale handles sizing (a lone 26×26 button in the still-spacious cards would look
off). Fix: every intent-tinted control mixed `intent 13%` into `--shed-inset` (a warm BEIGE),
muddying blue/amber/red all toward tan. Rework to `color-mix(in srgb, ${v} 14%, var(--shed-surface))`
bg + `color-mix(in srgb, ${v} 34%, var(--shed-border))` border (`srgb` matches Swift's
`opacity()` alpha compositing; over the near-white card surface, NOT the beige inset; mixed into
`--shed-border` not `transparent` per the fold). Applied to `IconBtn` + the RC `rcStateTone` pill
(18%, Swift StatePill `0.18`) + the LaunchForm kind toggle + Open-in-Claude + Launch. Verified on
screen: the running-shed terminal button now reads clean BLUE (was tan), reset amber, stop red.
(Original sweep list — the RC `rcStateTone` pill, the LaunchForm kind toggle,
the "Open in Claude" link, the "Launch" button, the sidebar active state uses `accent-subtle`
(fine — leave). Keep `hbtn`, titles, `disabled`, `spin`. **AC:** re-screenshot — the three
running-shed buttons read clean blue / amber / red (not tan), sized like Swift.

### M4 — Dashboard dense-parity rescale (`App.tsx` + `index.css`)
Port every pane to the Swift scale (table above). Mechanical but broad — may land as 1–2
commits (e.g. 4a shell+Sheds, 4b other panes+modals), each green.
- **Shell:** sidebar `w-[232px]→w-[200px]`, nav rows to `13`/icon 16, count pill `11`;
  header `h-[52px]` chrome to `13 medium` + 7px dot + `12`; main content left-aligned
  `px-5`/`py-4`-ish, drop the `max-w-[880px]` centering (Swift fills). Keep `data-pane`.
- **`PageHead`/`HeadAction`:** title `22→26 bold`; **`HeadAction` filled button → a Swift
  text+icon accent link** (`13 medium` accent, no fill) for New shed / New session / Refresh.
- **Sheds:** shed name `19→14 semibold`, `Tag`/`ImageChip` to `10 medium`, meta `14→12`,
  row `py-[18px]→py-3` (`H14 V12`), dot 11→8, host header `12→11`.
- **Approvals:** card `p-5→p-[14px]`, title `18→14 semibold`, icon box `44→32` r8, sub `14→12`,
  Approve/Deny `15→13 medium` pad `H14 V7`; expiry `14→12 medium`.
- **Agents:** state pill to `11 medium` w-84 r6; name `16→14`; Open-in-Claude/Terminal/Kill to
  Swift sizes; card `py-3.5→V12`.
- **Activity:** ONE card wrapping Divider-separated rows (Swift), time `13→11 mono` w66, op
  `14→12`, result `13→12`; ns pill `11`.
- **System:** host name `17→14 semibold`, total `19→13 semibold`, metric label `12→10` value
  `15→12 mono`, icon 20→~14, card `py-4→14`.
- **Modals (Preferences/Create):** titles `19→` Swift dialog scale, field labels `12`, inputs
  to Swift sizes; keep `data-prefs`/`data-create`/`data-launch-at-login`/`data-ssh-*` hooks.
- **AC (per-pane checklist, computer-use re-screenshot each):** Sheds · Approvals · Agents ·
  Activity · System · Preferences · Create each match its Swift counterpart's type/spacing scale;
  all `data-*` hooks intact + `computed_style()` returns non-transparent `bg` + non-empty `accent`.

### M5 — Dark-theme + cross-surface verification
Re-screenshot every touched surface in dark mode (MANUAL — click the header moon toggle via
computer-use, then screenshot; no harness dark-toggle op per the fold). Verify tints/borders/hover
read correctly in dark — specifically the IntentButton border must stay VISIBLE against the dark
surface (the fold's `srgb`-mix-into-`--shed-border` recipe; promote to per-mode `--shed-<intent>-tint`
tokens if it washes out). Run the **full render gate** (`tauri-test-linux` + `tauri-build-linux`) —
any oklch/color-mix change MUST pass it — plus `make core-test` ONCE (belt-and-suspenders). Final
side-by-side screenshot set (Swift vs Tauri, per pane + tray + popover, light + dark).

## Drivability guardrails (must stay green every commit)
- `data-pane` / `data-prefs` / `data-create` / `data-launch-at-login` / `data-ssh-policy` /
  `data-ssh-ttl` / `data-tray-popover` attributes + `reportAgents`/`reportTray` calls — unchanged.
- The computed-style probe reads `body` bg/color + `[data-pane]`'s `--shed-accent` — keep the
  tokens on `body`/`:root` + a `[data-pane]` element. (`test_computed_style_probe_confirms_theme`.)
- No IPC-op signature changes except ADDING `resize_popover` (mac-only, popover capability). The
  `ui.*`/`tray.*`/`dashboard.dump`/`agents.dump` readers keep the `main`/`popover` label keys.
- Gates each commit (per panel fold): `source ~/.cargo/env` → `make tauri-test` ·
  `make e2e-tauri` · (shared CSS →) `make tauri-test-linux` + `make tauri-build-linux`.
  `make core-test` is NOT exercised by these changes → run it ONCE in M5. Always `cd /abs/path`
  before `make` (cwd-drift no-ops a bare make from a subdir).

## Guardrails
- **Do NOT modify `Sources/`** (the Swift app is the read-only reference).
- Tune both light + dark tokens if touched. Keep it macOS-focused; Linux render gate green.
- New tray/app icons regenerate via `packaging/icon/regenerate.sh`.
