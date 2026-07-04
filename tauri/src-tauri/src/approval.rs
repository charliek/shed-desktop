//! Production impls of the approval seams (test mode uses shed-app's fakes).
//!
//! The real native gate is **polkit** (via `pkcheck`) and the notifier is
//! **libnotify** (`notify-send`) — both `#[cfg(target_os = "linux")]`, because the
//! Tauri crate also builds on macOS for dev + the e2e harness, where the fail-closed
//! stubs ([`FailClosedGate`] → `Unavailable`, [`NoopNotifier`]) stand in. The gate
//! shells out to the polkit-provided tools rather than linking a D-Bus crate: the
//! user's secret is entered into the OS polkit agent, never this app (TB5), and a
//! missing tool fails **closed** (`Unavailable`) with no new dependency to audit.
//!
//! The button-only ("prompt") method needs no gate and works everywhere; polkit
//! only *adds* the password-gated method on top (B6). Under the hermetic harness
//! the gate is bypassed (test-mode `AlwaysApprovedGate`), so the approval matrix is
//! green independent of polkit.

use std::sync::Arc;

use tauri::{AppHandle, Emitter};

use shed_app::traits::{
    AuthGate, AuthGateRef, AuthOutcome, AuthPrompt, CoordinatorEvent, EventSink, Notifier,
    NotifierRef,
};
use shed_core::approval::ApprovalRequest;

/// The production notifier + auth gate for the running platform. Linux gets the
/// real polkit gate + libnotify notifier; every other target (macOS dev/e2e) gets
/// the fail-closed stubs. Test mode never calls this — it uses shed-app's fakes.
pub fn production_seams() -> (NotifierRef, AuthGateRef) {
    #[cfg(target_os = "linux")]
    {
        (Arc::new(linux::NotifySendNotifier), Arc::new(linux::PolkitGate))
    }
    #[cfg(not(target_os = "linux"))]
    {
        (Arc::new(NoopNotifier), Arc::new(FailClosedGate))
    }
}

/// Forwards coordinator-state changes to the webview as Tauri events, so the
/// Approvals/Activity panes re-fetch reactively (no polling). The event names
/// match the `listen(...)` calls in the React bridge.
pub struct TauriEventSink {
    app: AppHandle,
}

impl TauriEventSink {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl EventSink for TauriEventSink {
    fn emit(&self, event: CoordinatorEvent) {
        let name = match event {
            CoordinatorEvent::Approvals => "approvals-changed",
            CoordinatorEvent::Activity => "activity-changed",
            CoordinatorEvent::Connected => "connected-changed",
        };
        let _ = self.app.emit(name, ());
    }
}

/// The non-Linux / no-desktop-notifications notifier: a no-op.
pub struct NoopNotifier;

impl Notifier for NoopNotifier {
    fn post(&self, _req: &ApprovalRequest) {}
    fn withdraw(&self, _id: &str) {}
}

/// The non-Linux auth gate: fail-closed. A biometric/password-gated approve can't
/// be confirmed, so the request stays pending and expires to deny (F5). The
/// button-only ("prompt") method needs no gate, so it still works.
pub struct FailClosedGate;

#[async_trait::async_trait]
impl AuthGate for FailClosedGate {
    async fn gate(&self, _prompt: AuthPrompt) -> AuthOutcome {
        AuthOutcome::Unavailable
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use shed_app::traits::{AuthGate, AuthOutcome, AuthPrompt, Notifier};
    use shed_core::approval::ApprovalRequest;

    /// The polkit action a credential approval authenticates against. Must match the
    /// `<action id>` in the shipped `packaging/polkit/*.policy` (installed to
    /// `/usr/share/polkit-1/actions/`); an unregistered action → `pkcheck` errors →
    /// `Unavailable` (fail-closed).
    const POLKIT_ACTION_ID: &str = "ai.stridelabs.shed-desktop.approve-credential";

    /// The real Linux gate: `pkcheck --allow-user-interaction` runs the registered
    /// polkit agent's password/PAM dialog and blocks for the result. The secret is
    /// entered into the OS agent, never this process. Runs inside the spawned gate
    /// task (never the actor), so the blocking wait doesn't head-of-line-block.
    pub struct PolkitGate;

    #[async_trait::async_trait]
    impl AuthGate for PolkitGate {
        async fn gate(&self, prompt: AuthPrompt) -> AuthOutcome {
            // F5: "biometrics only" can't be guaranteed via polkit/PAM on Linux
            // (PAM may fall back to a password) — fail closed until fprintd lands.
            if prompt.biometrics_only {
                return AuthOutcome::Unavailable;
            }
            // Authorize OUR process (the app requesting on behalf of its user);
            // pkcheck reads our start-time from /proc to pin the subject.
            let pid = std::process::id().to_string();
            // ABSOLUTE path, never a bare name: `success()` is the ONLY thing that
            // separates approve from deny, so a `pkcheck` shadowed earlier on PATH
            // (e.g. a malicious ~/.local/bin/pkcheck that `exit 0`s) would be a silent
            // gate bypass. A missing /usr/bin/pkcheck falls through to the spawn-Err
            // arm below → Unavailable (still fail-closed).
            match tokio::process::Command::new("/usr/bin/pkcheck")
                .args([
                    "--action-id",
                    POLKIT_ACTION_ID,
                    "--process",
                    &pid,
                    "--allow-user-interaction",
                ])
                .status()
                .await
            {
                // Exactly one value approves; everything else is deny-safe (the
                // coordinator leaves the request pending regardless of the variant).
                Ok(s) if s.success() => AuthOutcome::Approved,
                // Any non-zero exit = not authorized (a cancel or a wrong secret —
                // polkit's exact codes vary by version, so don't guess which). A
                // signal death is abnormal → Error. Both leave the request pending.
                Ok(s) if s.code().is_some() => AuthOutcome::Denied,
                Ok(_) => AuthOutcome::Error("pkcheck killed by signal".into()),
                // No /usr/bin/pkcheck (polkit not installed) or spawn failure → the
                // system can't gate → fail closed, distinctly from a user deny.
                Err(_) => AuthOutcome::Unavailable,
            }
        }
    }

    /// Posts an approval banner via libnotify (`notify-send`). Best-effort and
    /// fire-and-forget so the actor never blocks on the notification daemon; a
    /// missing `notify-send` just means no banner (approvals still work via the
    /// pane). Withdraw is a no-op — banners auto-expire; precise recall (a Notify
    /// id + `CloseNotification` over D-Bus) is a follow-up.
    pub struct NotifySendNotifier;

    impl Notifier for NotifySendNotifier {
        fn post(&self, req: &ApprovalRequest) {
            use shed_app::traits::approval_notification_text as text;
            let title = text::title(req);
            let body = text::body(req);
            // We're inside the coordinator actor (a tokio task), so spawn is valid.
            tokio::spawn(async move {
                // Absolute path (consistency with the gate); `--` terminates option
                // parsing so an attacker-influenced title/body (e.g. a shed op named
                // "--icon=…") can't be swallowed as a notify-send flag.
                let _ = tokio::process::Command::new("/usr/bin/notify-send")
                    .args([
                        "--app-name=shed-desktop",
                        "--icon=ai.stridelabs.shed-desktop",
                        "--urgency=critical",
                        "--",
                        &title,
                        &body,
                    ])
                    .status()
                    .await;
            });
        }
        fn withdraw(&self, _id: &str) {}
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::linux::PolkitGate;
    use shed_app::traits::{AuthGate, AuthOutcome, AuthPrompt};

    #[tokio::test]
    async fn biometrics_only_is_unavailable() {
        // F5: biometrics-only can't be honored via polkit on Linux — fail closed
        // without even invoking pkcheck.
        let out = PolkitGate
            .gate(AuthPrompt {
                reason: "r".into(),
                biometrics_only: true,
            })
            .await;
        assert_eq!(out, AuthOutcome::Unavailable);
    }

    #[tokio::test]
    async fn gate_never_approves_without_real_auth() {
        // No polkit agent / display / registered action in CI, so pkcheck — whether
        // absent (→ Unavailable) or present-but-unable-to-authorize (→ Denied/
        // Cancelled/Error) — must NEVER yield Approved. The single most important
        // property of the gate: it can't approve without a real authentication.
        let out = PolkitGate
            .gate(AuthPrompt {
                reason: "r".into(),
                biometrics_only: false,
            })
            .await;
        assert_ne!(out, AuthOutcome::Approved);
    }
}
