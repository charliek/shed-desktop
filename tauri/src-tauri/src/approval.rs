//! Production impls of the approval seams (test mode uses shed-app's fakes). The
//! real native notifier (D-Bus) + the polkit `AuthGate` land in B6; until then a
//! prod notification is a no-op and the native gate is **fail-closed**
//! (`Unavailable`), so the button-only ("Prompt") method works while a
//! password-gated request stays pending → expire-to-deny (fail-closed, F5).

use tauri::{AppHandle, Emitter};

use shed_app::traits::{AuthGate, AuthOutcome, AuthPrompt, CoordinatorEvent, EventSink, Notifier};
use shed_core::approval::ApprovalRequest;

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

/// A no-op notifier (real native notifications land in B6).
pub struct NoopNotifier;

impl Notifier for NoopNotifier {
    fn post(&self, _req: &ApprovalRequest) {}
    fn withdraw(&self, _id: &str) {}
}

/// The native gate before polkit (B6): fail-closed. A biometric/password-gated
/// approve can't be confirmed, so the request stays pending and expires to deny.
/// The button-only ("Prompt") method needs no gate, so it still works.
pub struct FailClosedGate;

#[async_trait::async_trait]
impl AuthGate for FailClosedGate {
    async fn gate(&self, _prompt: AuthPrompt) -> AuthOutcome {
        AuthOutcome::Unavailable
    }
}
