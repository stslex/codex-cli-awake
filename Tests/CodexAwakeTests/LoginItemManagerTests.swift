import XCTest
@testable import CodexAwake

final class LoginItemManagerTests: XCTestCase {
    func testEnabledPresentationOffersUnregister() {
        let status = LoginItemStatus(state: .enabled, desired: true, detail: nil)

        XCTAssertEqual(
            LoginItemMenuPresentation.make(status: status),
            LoginItemMenuPresentation(
                title: "Launch at Login",
                symbolName: "checkmark.circle.fill",
                isChecked: true,
                action: .unregister
            )
        )
        XCTAssertEqual(LoginItemCommandExitCode.registration(status), EXIT_SUCCESS)
    }

    func testApprovalPresentationOpensSystemSettings() {
        let status = LoginItemStatus(
            state: .requiresApproval,
            desired: true,
            detail: "Approval required"
        )

        XCTAssertEqual(
            LoginItemMenuPresentation.make(status: status).action,
            .openSettings
        )
        XCTAssertEqual(LoginItemCommandExitCode.registration(status), 2)
    }

    func testDisabledPreferenceMakesReconciledUnregistrationSuccessful() {
        let status = LoginItemStatus(state: .notRegistered, desired: false, detail: nil)

        XCTAssertEqual(
            LoginItemMenuPresentation.make(status: status),
            LoginItemMenuPresentation(
                title: "Launch at Login",
                symbolName: "circle",
                isChecked: false,
                action: .register
            )
        )
        XCTAssertEqual(LoginItemCommandExitCode.reconciliation(status), EXIT_SUCCESS)
        XCTAssertEqual(LoginItemCommandExitCode.unregistration(status), EXIT_SUCCESS)
    }

    func testDesiredButUnavailablePresentationSurfacesFailure() {
        let status = LoginItemStatus(
            state: .notFound,
            desired: true,
            detail: "Missing bundle"
        )

        XCTAssertEqual(
            LoginItemMenuPresentation.make(status: status).title,
            "Launch at Login (Unavailable)"
        )
        XCTAssertEqual(LoginItemCommandExitCode.registration(status), EXIT_FAILURE)
    }
}
