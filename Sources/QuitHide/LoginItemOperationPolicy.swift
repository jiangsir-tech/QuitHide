enum LoginItemObservedStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

enum LoginItemRequestedOperation: Equatable, Sendable {
    case none
    case register
    case unregister
    case showApprovalInstructions
    case unsupported
}

/// Translates the user's desired launch-at-login state into an operation.
///
/// In particular, `.notFound` is an observation failure rather than proof that
/// registration cannot succeed. An explicit enable request must still call the
/// registration API so the system can recover or return a useful error.
enum LoginItemOperationPolicy {
    static func operation(
        launchAtLoginShouldBeEnabled enabled: Bool,
        observedStatus: LoginItemObservedStatus
    ) -> LoginItemRequestedOperation {
        if enabled {
            switch observedStatus {
            case .enabled:
                return .none
            case .requiresApproval:
                return .showApprovalInstructions
            case .notRegistered, .notFound:
                return .register
            case .unknown:
                return .unsupported
            }
        }

        switch observedStatus {
        case .notRegistered, .notFound:
            return .none
        case .enabled, .requiresApproval:
            return .unregister
        case .unknown:
            return .unsupported
        }
    }
}
