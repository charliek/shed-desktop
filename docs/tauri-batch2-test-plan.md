# Tauri Batch 2 — hands-on test plan (B1 menu · A4 D-Bus · B4 SSH prefs)

The three Phase C "Batch 2" items, each landed as its own commit on `tauri-phase-c`
(PR #29). This is the maintainer's hands-on runbook — the automated gates
(`make e2e-tauri`, `make tauri-test-linux`, CI `tauri-linux`/`tauri-mac`) already pass;
these steps confirm the bits a headless harness can't (real tray clicks, a real
notification daemon, a real app restart).

Build for a hands-on run:

```bash
make tauri-run                 # macOS dev build
make tauri-build-linux         # or exercise on Linux via the render-gate image
```

---

## B1 — expanded tray menu (`feat(tauri): Phase C B1 …`)

The tray menu was **Open Dashboard / Quit**; it's now **Open Dashboard / Approvals /
Preferences… / Quit**. On Linux the menu *is* the tray surface (no click events, no
popover); on macOS it opens on left-click for now (the rich popover is the deferred
B1b spike — see below).

**macOS + Linux**
1. Click (macOS) / right-click (Linux) the menu-bar/tray icon → the menu shows four items.
2. **Approvals** → the dashboard raises and switches to the Approvals pane.
3. **Preferences…** → the dashboard raises and the Preferences modal opens.
4. **Open Dashboard** → raises the dashboard (last pane). **Quit** → exits.

Drive-by check (drivable-over-IPC, the North Star):
```bash
shedctl-tauri tray.dump      # → { present, items: ["open","approvals","preferences","quit"] }
```

---

## A4 — approval banners are recalled over D-Bus (Linux) (`feat(tauri): Phase C A4 …`)

**Linux only.** Previously a credential-approval banner was posted via `notify-send`
and never taken down — an `--urgency=critical` banner does not auto-expire, so it
lingered after you'd already approved/denied. Now the notifier posts + closes the
*exact* banner over the freedesktop Notifications interface (zbus).

**On a Linux desktop with a notification daemon (dunst / GNOME / KDE):**
1. Trigger a credential approval (an SSH sign from a gated shed) → a critical banner appears.
2. Approve (or deny) it in the dashboard, or let it expire.
3. **The banner disappears** as soon as the request resolves — it no longer lingers.
4. Re-post case: cause the host to re-send the same request id (a replacement) → only
   **one** banner is ever on screen; the previous one is retracted, not orphaned.
5. No-daemon case: kill the notification daemon, trigger an approval → no banner, but
   the approval still works via the Approvals pane (no crash, no hang).

Drive-by check: `notifications.list` now reflects the *real* posted banners on a live
desktop (it used to be empty for the real notifier — only the test fake tracked them).

> Note: the notification **body** is markup-escaped, so a shed op/detail containing
> `<b>`/`<a …>` can't spoof the banner on a `body-markup`-capable daemon.

---

## B4 — SSH approval preferences persist + full controls (`feat(tauri): Phase C B4 …`)

The Preferences modal's **Credential approvals** section exposed **method only**; it
now mirrors the Swift app's "SSH approvals" section — an **Approval policy** picker, a
**Duration** field (shown only for the time-based policy), and the **Method** picker
(shown only for prompting policies). And the choices now **persist across restarts**
(the coordinator used to start from `SshPrefs::default()`, unhydrated).

**macOS + Linux**
1. Open **Preferences… → Credential approvals**.
2. Change the **Approval policy** → the Duration / Method controls appear/hide to match
   (Duration only on *Time Based Allow*; Method hidden on *Always Allow* / *Always Deny*).
3. Set a policy + duration + method.
4. **Quit and relaunch the app** → reopen Preferences → your choices are still there.
5. Confirm the running policy took effect (*Always Allow* signs with no prompt; a
   prompting policy prompts), then re-check after restart.

Drive-by check (the set→observe pair the harness asserts):
```bash
shedctl-tauri ui.set_ssh_approval '{"policy":"time-based-allow","ttl":"4h","method":"prompt"}'
shedctl-tauri ui.ssh_prefs           # → { method, policy, ttl } reflecting the set
```

---

## Deferred (not in this batch — need your call / presence)

- **B1b — the macOS rich popover.** The panel review found this is materially bigger
  than a thin layer (window-keyed `ui_report`, a `tray.show` drive op, a positioner +
  popover window + a new React entry, role-aware activation policy). It also needs your
  native-feel verdict (Tauri popover vs. the native `NSStatusItem` fallback), so it's a
  budgeted spike → screenshot → checkpoint, not an autonomous "done".
- **B4 — launch-at-login.** A new `tauri-plugin-autostart` dep with real side effects
  (registers a login item) and a logout/login cycle to verify — cleaner to land with
  you present to test.
- **B1 — the Linux pending-count menu item.** Low value on a menu item vs. a macOS
  badge; folded into the B1b popover work.
