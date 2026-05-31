// Policy engine matrix — pure, no I/O (spec §7.3).

import XCTest
@testable import ShedKit

final class PolicyEngineTests: XCTestCase {
    private func req(ns: String = "ssh-agent", shed: String = "stbot") -> ApprovalRequest {
        ApprovalRequest(id: "1", ts: "t", namespace: ns, op: "sign", shed: shed, detail: "ed25519", expiresAt: "t")
    }

    func testDefaultRuleApplies() {
        let e = PolicyEngine(rules: [PolicyRule(scope: .default, action: .prompt, gate: .touchid)])
        let d = e.decide(for: req(), sessionGrants: [])
        XCTAssertEqual(d.action, .prompt)
        XCTAssertEqual(d.appliedScope, .default)
    }

    func testNamespaceOverridesDefault() {
        let e = PolicyEngine(rules: [
            PolicyRule(scope: .default, action: .prompt, gate: .touchid),
            PolicyRule(scope: .namespace, namespace: "ssh-agent", action: .deny, gate: .none),
        ])
        let d = e.decide(for: req(ns: "ssh-agent"), sessionGrants: [])
        XCTAssertEqual(d.action, .deny)
        XCTAssertEqual(d.appliedScope, .namespace)
        // A different namespace falls back to default.
        XCTAssertEqual(e.decide(for: req(ns: "aws-credentials"), sessionGrants: []).appliedScope, .default)
    }

    func testShedOverridesNamespace() {
        let e = PolicyEngine(rules: [
            PolicyRule(scope: .default, action: .prompt),
            PolicyRule(scope: .namespace, namespace: "ssh-agent", action: .prompt),
            PolicyRule(scope: .shed, shed: "stbot", action: .approve, gate: .none),
        ])
        let d = e.decide(for: req(shed: "stbot"), sessionGrants: [])
        XCTAssertEqual(d.action, .approve)
        XCTAssertEqual(d.appliedScope, .shed)
    }

    func testSessionGrantWinsOverEverything() {
        let e = PolicyEngine(rules: [
            PolicyRule(scope: .default, action: .deny, gate: .none),
            PolicyRule(scope: .shed, shed: "stbot", action: .deny, gate: .none),
        ])
        let grants: Set<SessionGrantKey> = [SessionGrantKey(namespace: "ssh-agent", shed: "stbot")]
        let d = e.decide(for: req(), sessionGrants: grants)
        XCTAssertEqual(d.action, .approve)
        XCTAssertEqual(d.appliedScope, .session)
        // A grant for a different shed does not apply → falls to default deny.
        XCTAssertEqual(e.decide(for: req(shed: "other"), sessionGrants: grants).action, .deny)
    }

    func testNoRulesFailsSafeToPrompt() {
        let e = PolicyEngine(rules: [])
        let d = e.decide(for: req(), sessionGrants: [])
        XCTAssertEqual(d.action, .prompt)
        XCTAssertEqual(d.gate, .touchid)
    }
}
