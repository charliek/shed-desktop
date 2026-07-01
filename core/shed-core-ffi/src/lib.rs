//! UniFFI bridge over `shed-core` → Swift. Kept thin so Phase 3's GTK app can
//! link `shed-core` directly without paying for UniFFI.

use std::sync::Arc;

uniffi::setup_scaffolding!();

/// M0 canary: an async export routed through the shared tokio runtime. Proves
/// the async-over-FFI path compiles + generates before the real client lands.
#[uniffi::export(async_runtime = "tokio")]
pub async fn ping(echo: String) -> String {
    shed_core::ping(echo).await
}

/// A Swift→Rust async callback, mirroring the shape of the real Phase 3
/// `TokenMinter` (Rust owns the token FSM; the host-agent mint stays foreign).
/// M0 proves the async-foreign-callback FFI mechanism before M3 depends on it.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait MinterProbe: Send + Sync {
    async fn mint(&self, server: String) -> String;
}

/// Callback canary: Rust calls back into the foreign minter and returns its result.
#[uniffi::export(async_runtime = "tokio")]
pub async fn mint_via(minter: Arc<dyn MinterProbe>, server: String) -> String {
    minter.mint(server).await
}

/// Cancellation canary: a delayed async op the Swift side starts and cancels.
#[uniffi::export(async_runtime = "tokio")]
pub async fn slow_echo(echo: String, delay_ms: u64) -> String {
    tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
    format!("slow: {echo}")
}
