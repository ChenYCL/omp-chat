import XCTest
@testable import OMPCore

final class ApprovalPolicyTests: XCTestCase {
    func testFullTableWithoutAlwaysAllow() {
        let expected: [PermissionMode: [ToolRisk: ApprovalPolicy.Decision]] = [
            .readOnly: [.read: .allow, .write: .deny, .execute: .deny, .control: .deny],
            .ask: [.read: .allow, .write: .ask, .execute: .ask, .control: .ask],
            .auto: [.read: .allow, .write: .allow, .execute: .ask, .control: .ask],
            .full: [.read: .allow, .write: .allow, .execute: .allow, .control: .ask],
        ]
        for mode in PermissionMode.allCases {
            for risk in ToolRisk.allCases {
                XCTAssertEqual(
                    ApprovalPolicy.decide(mode: mode, risk: risk, alwaysAllowed: false), expected[mode]?[risk],
                    "\(mode) / \(risk)"
                )
            }
        }
    }

    func testAlwaysAllowTurnsAskIntoAllowButNeverOverridesDeny() {
        for mode in PermissionMode.allCases {
            for risk in ToolRisk.allCases {
                let base = ApprovalPolicy.decide(mode: mode, risk: risk, alwaysAllowed: false)
                let always = ApprovalPolicy.decide(mode: mode, risk: risk, alwaysAllowed: true)
                switch base {
                case .ask: XCTAssertEqual(always, risk == .control ? .ask : .allow, "\(mode) / \(risk)")
                case .deny: XCTAssertEqual(always, .deny, "始终允许不能越过只读：\(mode) / \(risk)")
                case .allow: XCTAssertEqual(always, .allow, "\(mode) / \(risk)")
                }
            }
        }
        XCTAssertEqual(ApprovalPolicy.decide(mode: .auto, risk: .execute, alwaysAllowed: true), .allow)
        XCTAssertEqual(ApprovalPolicy.decide(mode: .ask, risk: .write, alwaysAllowed: true), .allow)
        XCTAssertEqual(ApprovalPolicy.decide(mode: .readOnly, risk: .execute, alwaysAllowed: true), .deny)
    }

    func testDesktopControlAsksEveryTimeEvenWhenAlwaysAllowed() {
        for mode in [PermissionMode.ask, .auto, .full] {
            XCTAssertEqual(ApprovalPolicy.decide(mode: mode, risk: .control, alwaysAllowed: true), .ask, "\(mode)")
        }
        XCTAssertEqual(ApprovalPolicy.decide(mode: .readOnly, risk: .control, alwaysAllowed: true), .deny)
    }
}
