import Foundation
import XCTest

@testable import ShedKit

final class ResolvedEndpointTests: XCTestCase {
    func testHTTPSApiURLKeepsPin() {
        let e = ShedServerEntry(
            name: "localmac", host: "localhost", httpPort: 8080, sshPort: 2222,
            apiURL: "https://localhost:8443", tlsCertFingerprint: "sha256:abc")
        let r = e.resolvedEndpoint()
        XCTAssertEqual(r.baseURL.absoluteString, "https://localhost:8443")
        XCTAssertEqual(r.pin, "sha256:abc")
    }

    func testPlainHTTPFallbackWhenNoApiURL() {
        let e = ShedServerEntry(name: "mini2", host: "mini2", httpPort: 8080, sshPort: 2222)
        let r = e.resolvedEndpoint()
        // This is exactly the resolution a stale build got wrong (dialed :8080).
        XCTAssertEqual(r.baseURL.absoluteString, "http://mini2:8080")
        XCTAssertEqual(r.pin, "")
    }
}
