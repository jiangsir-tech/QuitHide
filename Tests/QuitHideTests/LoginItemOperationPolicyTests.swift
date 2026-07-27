import Testing
@testable import QuitHide

@Suite("Login item operation policy")
struct LoginItemOperationPolicyTests {
    @Test("Enabling an unregistered login item registers it")
    func enableNotRegistered() {
        #expect(operation(enabled: true, status: .notRegistered) == .register)
    }

    @Test("Enabling after a not-found observation still attempts registration")
    func enableNotFound() {
        #expect(operation(enabled: true, status: .notFound) == .register)
    }

    @Test("A future status avoids guessing which system API is safe")
    func enableUnknown() {
        #expect(operation(enabled: true, status: .unknown) == .unsupported)
    }

    @Test("An enabled login item does not register twice")
    func enableAlreadyEnabled() {
        #expect(operation(enabled: true, status: .enabled) == .none)
    }

    @Test("Approval is handled in System Settings")
    func enableRequiresApproval() {
        #expect(
            operation(enabled: true, status: .requiresApproval)
                == .showApprovalInstructions
        )
    }

    @Test("Disabling a registered login item attempts cleanup", arguments: [
        LoginItemObservedStatus.enabled,
        .requiresApproval
    ])
    func disableRegisteredOrUncertain(status: LoginItemObservedStatus) {
        #expect(operation(enabled: false, status: status) == .unregister)
    }

    @Test("Disabling after a not-found observation is already off")
    func disableNotFound() {
        #expect(operation(enabled: false, status: .notFound) == .none)
    }

    @Test("Disabling an unknown future state does not guess")
    func disableUnknown() {
        #expect(operation(enabled: false, status: .unknown) == .unsupported)
    }

    @Test("Disabling an unregistered login item is a no-op")
    func disableNotRegistered() {
        #expect(operation(enabled: false, status: .notRegistered) == .none)
    }

    private func operation(
        enabled: Bool,
        status: LoginItemObservedStatus
    ) -> LoginItemRequestedOperation {
        LoginItemOperationPolicy.operation(
            launchAtLoginShouldBeEnabled: enabled,
            observedStatus: status
        )
    }
}
