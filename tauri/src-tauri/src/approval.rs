//! Production impls of the approval seams (test mode uses shed-app's fakes). The
//! real native notifier (D-Bus) + the polkit `AuthGate` land in B6; until then a
//! prod notification is a no-op and the native gate is **fail-closed**
//! (`Unavailable`), so the button-only ("Prompt") method works while a
//! password-gated request stays pending → expire-to-deny (fail-closed, F5).

use shed_app::traits::{AuthGate, AuthOutcome, AuthPrompt, Notifier};
use shed_core::approval::ApprovalRequest;

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
