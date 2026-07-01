//! shed-core — the pure Rust shed-server protocol client + wire DTOs.
//!
//! No UniFFI here; the `shed-core-ffi` crate wraps this for Swift. Phase 3's
//! GTK app links this crate directly. Decoders in `models` must reproduce the
//! defensive semantics pinned by shed-desktop's `ModelDecodingTests` exactly.

pub mod http;
pub mod models;

/// M0 canary health check, exercised through the FFI bridge until the real
/// client lands in M2. Async so the UniFFI async-over-tokio path is proven early.
pub async fn ping(echo: String) -> String {
    format!("shed-core ok: {echo}")
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn ping_echoes() {
        assert_eq!(super::ping("hi".into()).await, "shed-core ok: hi");
    }
}
