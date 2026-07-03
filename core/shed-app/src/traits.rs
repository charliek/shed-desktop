//! Platform-seam traits shared by the shed clients. The pure decision logic
//! lives in `shed-core`; these are the I/O / platform boundaries the coordinator
//! and the host-agent client depend on, so `shed-app` stays UI-free. GTK ignores
//! the approval seams; Tauri implements them (B3+). This module grows as later
//! milestones add `AuthGate` / `Notifier` / `Paths`.

use std::sync::Arc;

/// Injectable "now", so the expiry / TTL / grant / TOCTOU edge-cases are
/// deterministic in tests. `now_iso8601` formats the wire `ts` fields
/// (hello / pong / approval_response / audit) off `now_unix`, keeping timestamp
/// formatting in `shed-app` (`shed-core` stays parse/format-free).
pub trait Clock: Send + Sync {
    fn now_unix(&self) -> i64;
    fn now_iso8601(&self) -> String {
        crate::timefmt::format_iso8601(self.now_unix())
    }
}

/// A shared clock handle (the coordinator + host-agent client share one clock).
pub type ClockRef = Arc<dyn Clock>;

/// The real clock — the only place `shed-app` reads the wall clock (chrono's
/// `clock` feature is disabled precisely so "now" flows through this seam).
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_unix(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }
}

/// A `SystemClock` behind an `Arc`, for wiring into the client/coordinator.
pub fn system_clock() -> ClockRef {
    Arc::new(SystemClock)
}
