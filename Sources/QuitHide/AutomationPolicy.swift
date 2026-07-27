import Foundation

enum AutomationDefaults {
    static let unconfiguredHideEnabled = false
    static let preQuitHideEnabled = false
    static let stageManagerGroupProtectionEnabled = false
    static let screenVisibilityProtectionEnabled = false
}

enum AutoAction: String, CaseIterable, Codable {
    case unset
    case hide
    case quit
    case ignore

    var title: String {
        switch self {
        case .unset: return "按默认规则"
        case .hide: return "隐藏"
        case .quit: return "退出"
        case .ignore: return "不处理"
        }
    }

    var symbol: String {
        switch self {
        case .unset: return "arrow.triangle.branch"
        case .hide: return "eye.slash"
        case .quit: return "xmark.circle"
        case .ignore: return "checkmark.circle"
        }
    }

    var isAutomated: Bool {
        self == .hide || self == .quit
    }

    var rulePickerTitle: String {
        switch self {
        case .ignore: return "不处理"
        case .unset: return "未设置"
        case .hide: return "自动隐藏"
        case .quit: return "自动退出"
        }
    }

    static var rulePickerOrder: [AutoAction] {
        [.ignore, .unset, .hide, .quit]
    }
}

enum AutomationPolicy {
    static func effectiveAction(
        explicitAction: AutoAction,
        defaultHideEnabled: Bool
    ) -> AutoAction {
        guard explicitAction == .unset else { return explicitAction }
        return defaultHideEnabled ? .hide : .unset
    }

    static func idleMinutes(
        explicitAction: AutoAction,
        explicitMinutes: Int?,
        defaultHideMinutes: Int
    ) -> Int {
        let fallback = max(defaultHideMinutes, 1)
        guard explicitAction.isAutomated, let explicitMinutes else { return fallback }
        return max(explicitMinutes, 1)
    }
}
