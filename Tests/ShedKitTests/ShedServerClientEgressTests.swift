// ShedServerClient.egressProfiles() decode tests — the GET /api/egress/profiles
// wire shape (array of {name, source, profile:{mode,allow,deny,rule}}).

import Foundation
import XCTest

@testable import ShedKit

final class ShedServerClientEgressTests: XCTestCase {
    private func client() -> ShedServerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ShedServerClient(
            baseURL: URL(string: "http://stub.local")!, serverName: "t",
            session: URLSession(configuration: config))
    }

    func testEgressProfilesDecode() async throws {
        let body = """
            [
              {"name":"audit","source":"config","profile":{"mode":"audit"}},
              {"name":"my-stack","source":"user","profile":{"allow":["example.net","*.example.com"],"deny":["tracker.io"],"rule":"port == 443"}}
            ]
            """
        StubURLProtocol.reset([.init(status: 200, body: Data(body.utf8))])

        let profiles = try await client().egressProfiles()
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].name, "audit")
        XCTAssertEqual(profiles[0].source, "config")
        XCTAssertEqual(profiles[0].profile.mode, "audit")
        XCTAssertNil(profiles[0].profile.allow)
        XCTAssertEqual(profiles[1].source, "user")
        XCTAssertEqual(profiles[1].profile.allow, ["example.net", "*.example.com"])
        XCTAssertEqual(profiles[1].profile.deny, ["tracker.io"])
        XCTAssertEqual(profiles[1].profile.rule, "port == 443")
    }

    func testEgressProfilesEmptyArray() async throws {
        StubURLProtocol.reset([.init(status: 200, body: Data("[]".utf8))])
        let profiles = try await client().egressProfiles()
        XCTAssertTrue(profiles.isEmpty)
    }
}
