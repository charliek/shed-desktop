# Tauri Batch 3 — hands-on test plan (B4 launch-at-login · B3 Touch-ID · B1b popover · A5/B7)

The four Phase C "Batch 3" items, each landed as its own commit on `tauri-phase-c-batch3`
(off `feat/rust-core` = `37e962b`). This is the maintainer's hands-on runbook — the automated
gates (`make e2e-tauri`, `make tauri-build-linux`/`tauri-test-linux`, CI `tauri-linux`/`tauri-mac`)
already pass; these steps confirm the bits a headless harness can't: a **real Touch-ID prompt**
(unsigned/ad-hoc builds can't present it; needs the Developer-ID/notarization flip-gate), a **real
login item**, the **native feel** of the popover (window chrome / tray anchoring / blur — the
webview-vs-`NSStatusItem` decision), and a **real `shed-host-agent`** end-to-end (A5/B7).

Build for a hands-on run (cargo lives at `~/.cargo/bin`):

```bash
source ~/.cargo/env
make tauri-run                 # macOS dev build (loads the embedded dist)
# or, a release-profile binary toward the flip:
cd tauri/src-tauri && cargo build --release   # target/release/shed-desktop-tauri
```

> **Note on `make tauri-run`:** it runs the app in **production** mode (no `SHED_TAURI_TEST_MODE`),
> so the menu-bar-first launch + the real gate/login-item paths are exercised. The hermetic harness
> (`make e2e-tauri`) runs `SHED_TAURI_TEST_MODE=1`, which keeps `main` shown, never flips the
> activation policy, fakes the login-item write on macOS, and uses `AlwaysApprovedGate` (so the real
> Touch-ID gate is never invoked). The steps below need the **production** build.

---

## B1b — the macOS menu-bar rich popover (`feat(tauri): B1b.2 …`)

A 2nd, opaque, borderless webview mirroring the Swift `MenuBarContentView`: a host-agent status
dot, ≤3 pending-approval cards, ≤6 running sheds, and a footer. **macOS only** (Linux keeps the
native menu — Tauri emits no Linux tray click events). This is the deferred B1b spike; the goal of
the hands-on pass is the **native-feel call** (is the Tauri webview popover good enough, or does the
flip want a native `NSStatusItem` + reused `MenuBarContentView`? — see `plans/tauri-phase-c.md §8`).

**macOS (production build):**
1. Launch (`make tauri-run`). **Menu-bar-first:** no window + **no Dock icon** should appear — just
   the menu-bar (tray) icon. (Swift `.accessory` parity.)
2. **Left-click** the tray icon → the rich popover appears, **anchored under the tray icon**. Assess:
   the shadow, the opaque surface, the corner radius, the anchoring, the overall "does this feel like
   a native menu-bar app" — vs the Swift app's `NSPanel`.
3. Content: the host-agent dot is green when the agent is connected; running sheds are listed
   (`host/name`, ≤6); if there are pending approvals they show as ≤3 cards with approve/deny.
4. **Blur dismiss:** click anywhere outside the popover → it hides. (This is the one path automation
   can't drive — `tray.hide` stands in for it in the harness.)
5. Footer: **Open dashboard** → the dashboard window opens (a **Dock icon now appears** — `.regular`)
   on the Sheds pane, and the popover dismisses. **Preferences…** → opens the Preferences modal.
   **Check for Updates…** is **disabled** (greyed; the Tauri updater lands at the flip).
   **Quit** → exits.
6. **Right-click** the tray icon → the native menu (Open Dashboard / Approvals / Preferences… / Quit)
   still works (the fallback if a left-click doesn't register on your macOS — see the risk note).
7. Close the dashboard window → it hides to the tray and the **Dock icon disappears** (`.accessory`
   again); the app keeps running.

> **Risk to confirm:** whether `on_tray_icon_event` fires a **left-click** with a menu attached on
> your macOS. If a left-click does nothing (the menu doesn't detach), the click event may be swallowed
> — then the fallback is right-click for the menu, and we'd go **popover-only** on mac (the footer
> already carries the menu actions). Report which behavior you see.

Drive-by (drivable-over-IPC — the hermetic AC that already passes):
```bash
shedctl-tauri tray.dump   # → { present, items:[…], popover:{connected, running_sheds, pending_approvals}, popover_visible }
shedctl-tauri tray.show   # the exact Rust path a left-click runs → popover_visible=true
shedctl-tauri tray.hide
```

---

## B4 — launch-at-login (`feat(tauri): B4 launch-at-login …`)

A "Launch at login" toggle in Preferences → **General** (Swift `PreferencesView` parity), on
`tauri-plugin-autostart` (the `auto-launch` crate — macOS LaunchAgent / Linux `.desktop` autostart).

**macOS (production):**
1. Open Preferences (tray → Preferences… / the header gear). The **General** section is at the top
   with a **Launch at login** checkbox.
2. Toggle it **on** → confirm a login item appears: System Settings → General → Login Items → *Open at
   Login* lists **Shed Desktop** (or `~/Library/LaunchAgents` has the entry).
3. Log out + back in (or reboot) → the app launches menu-bar-first.
4. Toggle it **off** → the login item is removed.

**Linux (the shipped target):** the real `auto-launch` round-trip is exercised **automatically** on
the render gate (`test_loginitem_probe` writes/reads `$HOME/.config/autostart/*.desktop` under a
throwaway HOME). To eyeball: toggle it on → `~/.config/autostart/` gains the `.desktop`; off → removed.

Drive-by:
```bash
shedctl-tauri loginitem.status         # → { enabled: false }
shedctl-tauri loginitem.set '{"enabled": true}'   # macOS: guarded to an in-memory cell under test mode
```

---

## B3 — the macOS Touch-ID approval gate (`feat(tauri): B3 …`)

The real `LAContext.evaluatePolicy` gate (objc2) replaces the fail-closed stub, so a credential
approval routed to shed-desktop presents a **real Touch-ID / password prompt**. **Needs a signed
build** — Touch ID won't present from an unsigned/ad-hoc binary — so this is coupled to the
Developer-ID/notarization flip-gate + the A5 smoke below. The **deny-safe** paths are unit-tested
hermetically (`cargo test -p … approval::macos::tests` — `no_la_error_maps_to_approved`,
`unavailable_when_device_cannot_evaluate`).

**macOS (SIGNED build, with a live host-agent — see A5):**
1. With SSH approvals set to a prompting method + a biometric method (Preferences → SSH approvals),
   trigger an SSH sign that routes to shed-desktop.
2. → a real **Touch ID** prompt appears. **Approve** with your fingerprint → the credential is
   released; the Activity audit shows `decided_by = touchid`.
3. Trigger again + **cancel** the prompt → the request stays pending → expires to **deny** (no
   credential released).
4. A Mac **without** enrolled biometrics/passcode → the gate returns `Unavailable` (deny-safe) without
   prompting.

---

## A5 / B7 — the real-agent smoke (the flip gate)

The end-to-end pass, on a **real desktop** with a live `shed-host-agent` (holds real keys — the agent
does NOT start it) + a configured secure server. Full pass bar in `plans/tauri-phase-b.md §1`:

1. Start `shed-host-agent`; set its approval mode for a namespace to `shed-desktop`.
2. Launch the Tauri app → it shows **connected** (the host-agent dot is green).
3. A control token mints via `token.get` (no `401`s — a secure server's sheds appear).
4. An SSH sign routes an approval that the **Touch-ID gate approves end-to-end** (macOS) / the
   **polkit gate approves** (Linux) → the agent releases the credential; audit `decided_by` = touchid
   / polkit.
5. A **cancel** → the request expires to **deny** (no credential released).
6. **Kill the agent mid-pending** → the pending queue drops (F3); the connected dot flips back.

**Toward the flip (real build / packaging):** a release binary builds on mac (`cargo build --release`
in `tauri/src-tauri`) and Linux (the render-gate image). A full macOS `.app` (Developer-ID sign +
notarize) and the Linux `.deb` repackage (WebKit + `libayatana-appindicator` deps + the polkit
policy install) are the §4 Bar-2 flip-gate steps, not this batch.
