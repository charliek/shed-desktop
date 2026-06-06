// Per-provider approval model: method→gate, decision→action, TTL shorthand.

import XCTest
@testable import ShedKit

final class ApprovalModelTests: XCTestCase {
    func testMethodMapsToGate() {
        XCTAssertEqual(ApprovalMethod.biometricsOrPassword.gate, .biometricsOrPassword)
        XCTAssertEqual(ApprovalMethod.biometrics.gate, .biometrics)
        XCTAssertEqual(ApprovalMethod.prompt.gate, .none)
        // Only the biometric methods show a prompt / fingerprint icon.
        XCTAssertTrue(ApprovalMethod.biometricsOrPassword.gate.isBiometric)
        XCTAssertTrue(ApprovalMethod.biometrics.gate.isBiometric)
        XCTAssertFalse(ApprovalMethod.prompt.gate.isBiometric)
    }

    func testDecisionMapsToPolicyAction() {
        XCTAssertEqual(ApprovalDecision.approve.policyAction, .approve)
        XCTAssertEqual(ApprovalDecision.deny.policyAction, .deny)
    }

    func testTTLShorthand() {
        XCTAssertEqual(TTLShorthand.seconds("45s"), 45)
        XCTAssertEqual(TTLShorthand.seconds("4m"), 240)
        XCTAssertEqual(TTLShorthand.seconds("3h"), 3 * 3600)
        XCTAssertEqual(TTLShorthand.seconds("1d"), 86400)
        XCTAssertEqual(TTLShorthand.seconds(" 2H "), 2 * 3600) // trimmed + case-insensitive
        XCTAssertNil(TTLShorthand.seconds(""))
        XCTAssertNil(TTLShorthand.seconds("h"))
        XCTAssertNil(TTLShorthand.seconds("0h"))
        XCTAssertNil(TTLShorthand.seconds("3w"))
        XCTAssertNil(TTLShorthand.seconds("abc"))
    }

    func testCardDecisionMapsToChoice() {
        let always = CardDecision.alwaysAllow.choice(ttl: "2h")
        XCTAssertEqual(always.decision, .approve); XCTAssertTrue(always.persist); XCTAssertNil(always.scope)

        let perShed = CardDecision.perShedAllow.choice(ttl: "2h")
        XCTAssertEqual(perShed.decision, .approve); XCTAssertEqual(perShed.scope, .perShed)
        XCTAssertFalse(perShed.persist); XCTAssertNil(perShed.ttl)

        let timed = CardDecision.timeBasedAllow.choice(ttl: "3h")
        XCTAssertEqual(timed.decision, .approve); XCTAssertEqual(timed.scope, .perSession); XCTAssertEqual(timed.ttl, "3h")

        let ask = CardDecision.alwaysAsk.choice(ttl: "2h")
        XCTAssertEqual(ask.decision, .approve); XCTAssertEqual(ask.scope, .perRequest); XCTAssertFalse(ask.persist)

        let deny = CardDecision.alwaysDeny.choice(ttl: "2h")
        XCTAssertEqual(deny.decision, .deny); XCTAssertTrue(deny.persist)
    }

    func testCardDecisionOrderingAndFlags() {
        // allCases is the dropdown order: most → least permissive.
        XCTAssertEqual(CardDecision.allCases,
                       [.alwaysAllow, .perShedAllow, .timeBasedAllow, .alwaysAsk, .alwaysDeny])
        XCTAssertTrue(CardDecision.allCases.filter(\.usesDuration) == [.timeBasedAllow])
        XCTAssertTrue(CardDecision.allCases.filter(\.isDeny) == [.alwaysDeny])
    }

    func testCardDecisionNamespaceActionAndPrompts() {
        // The two "Always" options decide outright (no prompt); the rest prompt
        // and grant per their scope. Drives the SSH namespace rule + which
        // Preferences controls (Method/Duration) are shown.
        XCTAssertEqual(CardDecision.alwaysAllow.namespaceAction, .approve)
        XCTAssertEqual(CardDecision.alwaysDeny.namespaceAction, .deny)
        XCTAssertFalse(CardDecision.alwaysAllow.prompts)
        XCTAssertFalse(CardDecision.alwaysDeny.prompts)
        for d in [CardDecision.perShedAllow, .timeBasedAllow, .alwaysAsk] {
            XCTAssertEqual(d.namespaceAction, .prompt)
            XCTAssertTrue(d.prompts)
        }
    }

    func testCardDecisionDefaultScopeRoundTrip() {
        // The prompting subset maps 1:1 to ApprovalScope (no always-rules).
        for d in [CardDecision.perShedAllow, .timeBasedAllow, .alwaysAsk] {
            XCTAssertEqual(CardDecision(defaultScope: d.defaultScope!), d)
        }
        XCTAssertNil(CardDecision.alwaysAllow.defaultScope)
        XCTAssertNil(CardDecision.alwaysDeny.defaultScope)
        XCTAssertEqual(CardDecision(defaultScope: .perSession), .timeBasedAllow)
    }

    // The gate enum's wire values pin the protocol contract.
    func testGateWireValues() {
        XCTAssertEqual(PolicyGate.biometricsOrPassword.rawValue, "biometrics-or-password")
        XCTAssertEqual(PolicyGate.biometrics.rawValue, "biometrics")
        XCTAssertEqual(PolicyGate.none.rawValue, "none")
    }
}
