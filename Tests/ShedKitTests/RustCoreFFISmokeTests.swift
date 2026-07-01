// RustCoreFFISmokeTests — the M0 de-risk canary.
//
// Proves the Rust core is reachable over the UniFFI bridge from a Swift 6
// strict-concurrency test context, with the static library linked into the
// test binary (no dylib, no runtime loader). It exercises the three FFI
// mechanisms Phase 1 depends on, before the milestones that rely on them:
//   * an async method   (every read/write op — M2/M4),
//   * an async foreign callback Swift→Rust (the TokenMinter — M3),
//   * task cancellation across the boundary (abandoned create streams — M4).
// If this fails, the whole Phase 1 toolchain is blocked (plans/…/M0).

import XCTest
import ShedCore

final class RustCoreFFISmokeTests: XCTestCase {
    /// Async method over FFI.
    func testRustPingOverFFI() async throws {
        let result = await ping(echo: "canary")
        XCTAssertEqual(result, "shed-core ok: canary")
    }

    /// Swift→Rust async foreign callback — the shape the real TokenMinter uses.
    func testForeignAsyncCallback() async throws {
        let out = await mintVia(minter: StubMinter(), server: "mini2")
        XCTAssertEqual(out, "token-for-mini2")
    }

    /// Cancelling the Swift Task around an in-flight FFI call must not hang or
    /// crash. (True cancellation-propagation is exercised more fully in M4.)
    func testCancellationDoesNotHang() async throws {
        let task = Task { await slowEcho(echo: "x", delayMs: 200) }
        task.cancel()
        _ = await task.value
    }
}

/// A trivial `MinterProbe` conformer. `@unchecked Sendable`: its only state is
/// immutable, and it's handed to Rust across the async boundary.
private final class StubMinter: MinterProbe, @unchecked Sendable {
    func mint(server: String) async -> String { "token-for-\(server)" }
}
