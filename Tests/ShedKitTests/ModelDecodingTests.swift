// Decoding + config-parsing tests against the real shed-server shapes
// captured as fixtures (notably `{"sheds": null}` and mixed timestamps).

import XCTest
@testable import ShedKit

final class ModelDecodingTests: XCTestCase {
    func testShedDecodesRealServerFixture() throws {
        // The exact server shape: no `host` field, many optionals omitted.
        let json = """
        {"name":"hello-world","status":"running","created_at":"2026-05-31T13:33:00.884935839-05:00",
         "container_id":"fc-hello-world","backend":"firecracker","ip_address":"172.30.0.2","cpus":2,
         "memory_mb":4096,"pid":392574,"started_at":"2026-05-31T18:33:02.364547927Z"}
        """
        let shed = try JSONDecoder().decode(Shed.self, from: Data(json.utf8))
        XCTAssertEqual(shed.name, "hello-world")
        XCTAssertEqual(shed.status, .running)
        XCTAssertEqual(shed.backend, "firecracker")
        XCTAssertEqual(shed.cpus, 2)
        XCTAssertEqual(shed.memoryMB, 4096)
        XCTAssertEqual(shed.host, "")     // absent on the wire; client stamps it
        XCTAssertNil(shed.repo)           // omitted -> nil, not a decode failure
        XCTAssertEqual(shed.activeNamespaces, [])  // absent -> empty
    }

    func testShedListNullDecodesToEmpty() throws {
        struct Wrapper: Decodable { let sheds: [Shed]? }
        let w = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"sheds": null}"#.utf8))
        XCTAssertEqual(w.sheds ?? [], [])
    }

    func testUnknownStatusMapsToUnknown() {
        XCTAssertEqual(ShedStatus(serverValue: "provisioning"), .unknown)
        XCTAssertEqual(ShedStatus(serverValue: "running"), .running)
    }

    func testFlexibleTimestampParsesBothForms() {
        XCTAssertNotNil(DateFormatting.parseFlexibleTimestamp("2026-05-31T13:33:00.884935839-05:00"))
        XCTAssertNotNil(DateFormatting.parseFlexibleTimestamp("2026-05-31T18:33:02.364547927Z"))
        XCTAssertNotNil(DateFormatting.parseFlexibleTimestamp("2026-05-31T18:33:02Z (UTC)"))
        XCTAssertNil(DateFormatting.parseFlexibleTimestamp("not-a-date"))
    }

    func testConfigParsesServersAndDefault() {
        let yaml = """
        servers:
            mini2:
                host: mini2
                http_port: 8080
                ssh_port: 2222
                added_at: 2026-05-09T01:44:44.395385-05:00
            my-server:
                host: localhost
                http_port: 8080
                ssh_port: 2222
        default_server: mini2
        sheds: {}
        """
        let config = ShedConfig.parse(yaml)
        XCTAssertEqual(config.servers.count, 2)
        XCTAssertEqual(config.defaultServer, "mini2")
        let mini2 = config.servers.first { $0.name == "mini2" }
        XCTAssertEqual(mini2?.host, "mini2")
        XCTAssertEqual(mini2?.httpPort, 8080)
        XCTAssertEqual(mini2?.sshPort, 2222)
    }

    func testConfigMissingFileIsEmptyNotCrash() {
        let config = ShedConfig.load(path: "/nonexistent/\(UUID().uuidString)/config.yaml")
        XCTAssertEqual(config, .empty)
    }
}
