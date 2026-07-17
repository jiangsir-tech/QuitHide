import AppKit
import OSLog
import ServiceManagement
import SwiftUI

enum AutoAction: String, CaseIterable, Codable {
    case unset
    case hide
    case quit
    case ignore

    var title: String {
        switch self {
        case .unset: return "未设置"
        case .hide: return "隐藏"
        case .quit: return "退出"
        case .ignore: return "不处理"
        }
    }

    var symbol: String {
        switch self {
        case .unset: return "minus.circle"
        case .hide: return "eye.slash"
        case .quit: return "xmark.circle"
        case .ignore: return "checkmark.circle"
        }
    }

    var isAutomated: Bool {
        self == .hide || self == .quit
    }
}

struct ActionSymbol: View {
    let action: AutoAction

    private var tint: Color {
        switch action {
        case .unset, .ignore: return .secondary
        case .hide: return .blue.opacity(0.82)
        case .quit: return .red.opacity(0.82)
        }
    }

    var body: some View {
        Image(systemName: action.symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 20, height: 16, alignment: .center)
    }
}

struct RunningAppItem: Identifiable {
    let id: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let name: String
    let icon: NSImage
    let isHidden: Bool
    let isActive: Bool
    let app: NSRunningApplication
}

struct AppAutomationStatus {
    let text: String
    let isError: Bool
}

@MainActor
final class AppModel: ObservableObject {
    private final class BatchProgress {
        var remaining: Int
        var succeeded = 0
        var failed = 0

        init(total: Int) {
            remaining = total
        }
    }

    private static let logger = Logger(subsystem: "com.jiangsir.quithide", category: "automation")
    @Published var apps: [RunningAppItem] = []
    @Published var searchText = ""
    @Published var automationEnabled: Bool {
        didSet {
            defaults.set(automationEnabled, forKey: Keys.automationEnabled)
            guard automationEnabled != oldValue else { return }

            let now = Date()
            if automationEnabled {
                if let pauseStartedAt {
                    let pausedDuration = now.timeIntervalSince(pauseStartedAt)
                    inactiveSince = inactiveSince.mapValues {
                        $0.addingTimeInterval(pausedDuration)
                    }
                }
                pauseStartedAt = nil
            } else {
                pauseStartedAt = now
            }
        }
    }
    @Published var idleMinutes: Int {
        didSet { defaults.set(idleMinutes, forKey: Keys.idleMinutes) }
    }
    @Published var statusMessage = ""
    @Published var launchAtLogin = false

    private enum Keys {
        static let policies = "policies"
        static let policyIdleMinutes = "policyIdleMinutes"
        static let automationEnabled = "automationEnabled"
        static let idleMinutes = "idleMinutes"
    }

    private let defaults = UserDefaults.standard
    private var policies: [String: String]
    private var policyIdleMinutes: [String: Int]
    private var inactiveSince: [String: Date] = [:]
    private var alreadyHandled: Set<String> = []
    private var actionFailures: [String: AutoAction] = [:]
    private var pauseStartedAt: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let savedIdleMinutes = UserDefaults.standard.object(forKey: Keys.idleMinutes) as? Int ?? 20
        policies = defaults.dictionary(forKey: Keys.policies) as? [String: String] ?? [:]
        policyIdleMinutes = defaults.dictionary(forKey: Keys.policyIdleMinutes) as? [String: Int] ?? [:]
        automationEnabled = defaults.object(forKey: Keys.automationEnabled) as? Bool ?? true
        idleMinutes = savedIdleMinutes
        if !automationEnabled {
            pauseStartedAt = Date()
        }

        // Earlier versions stored an explicit "不处理" choice as "never",
        // while apps with no saved entry also appeared as "不处理". Preserve that
        // distinction by migrating saved choices to the explicit ignored state.
        let legacyIgnoredBundleIDs = policies.compactMap { key, value in
            value == "never" ? key : nil
        }
        if !legacyIgnoredBundleIDs.isEmpty {
            for bundleIdentifier in legacyIgnoredBundleIDs {
                policies[bundleIdentifier] = AutoAction.ignore.rawValue
            }
            defaults.set(policies, forKey: Keys.policies)
        }

        // Give rules created by earlier versions their own frozen duration instead
        // of leaving them tied to the default for newly-created rules.
        let missingDurations = policies.compactMap { bundleIdentifier, rawValue -> String? in
            guard AutoAction(rawValue: rawValue)?.isAutomated == true,
                  policyIdleMinutes[bundleIdentifier] == nil else { return nil }
            return bundleIdentifier
        }
        if !missingDurations.isEmpty {
            for bundleIdentifier in missingDurations {
                policyIdleMinutes[bundleIdentifier] = savedIdleMinutes
            }
            defaults.set(policyIdleMinutes, forKey: Keys.policyIdleMinutes)
        }

        refreshApps()
        installObservers()
        installTimer()
        refreshLoginStatus()
    }

    deinit {
        timer?.invalidate()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var filteredApps: [RunningAppItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    func policy(for bundleIdentifier: String) -> AutoAction {
        guard let raw = policies[bundleIdentifier] else { return .unset }
        return AutoAction(rawValue: raw) ?? .unset
    }

    func setPolicy(_ action: AutoAction, for bundleIdentifier: String) {
        if action == .unset {
            policies.removeValue(forKey: bundleIdentifier)
        } else {
            policies[bundleIdentifier] = action.rawValue
        }
        defaults.set(policies, forKey: Keys.policies)
        if action.isAutomated, policyIdleMinutes[bundleIdentifier] == nil {
            policyIdleMinutes[bundleIdentifier] = idleMinutes
            defaults.set(policyIdleMinutes, forKey: Keys.policyIdleMinutes)
        }
        alreadyHandled.remove(bundleIdentifier)
        actionFailures.removeValue(forKey: bundleIdentifier)
        objectWillChange.send()
    }

    func idleMinutes(for bundleIdentifier: String) -> Int {
        policyIdleMinutes[bundleIdentifier] ?? idleMinutes
    }

    func setIdleMinutes(_ minutes: Int, for bundleIdentifier: String) {
        policyIdleMinutes[bundleIdentifier] = max(minutes, 1)
        defaults.set(policyIdleMinutes, forKey: Keys.policyIdleMinutes)
        alreadyHandled.remove(bundleIdentifier)
        actionFailures.removeValue(forKey: bundleIdentifier)
        objectWillChange.send()
    }

    func automationStatus(for item: RunningAppItem) -> AppAutomationStatus? {
        let bundleID = item.bundleIdentifier
        let action = policy(for: bundleID)
        guard action.isAutomated else { return nil }

        if let failedAction = actionFailures[bundleID] {
            return AppAutomationStatus(text: "\(failedAction.title)失败", isError: true)
        }
        if item.isActive {
            return AppAutomationStatus(text: "使用中 · 离开后计时", isError: false)
        }
        if action == .hide, item.isHidden {
            return AppAutomationStatus(text: "已隐藏 · 激活后重计时", isError: false)
        }
        if alreadyHandled.contains(bundleID) {
            return AppAutomationStatus(text: "正在\(action.title)…", isError: false)
        }
        guard let inactiveAt = inactiveSince[bundleID] else {
            return AppAutomationStatus(text: "等待离开前台", isError: false)
        }

        let remaining = thresholdSeconds(for: bundleID) - effectiveNow.timeIntervalSince(inactiveAt)
        if remaining <= 0 {
            return AppAutomationStatus(text: "即将\(action.title)", isError: false)
        }

        let formatted = formatRemainingTime(remaining)
        if !automationEnabled {
            return AppAutomationStatus(text: "已暂停 · 剩余 \(formatted)", isError: false)
        }
        return AppAutomationStatus(text: "还剩 \(formatted) · 将\(action.title)", isError: false)
    }

    func immediateTargetCount(for action: AutoAction) -> Int {
        immediateTargets(for: action).count
    }

    func immediateTargetHelp(for action: AutoAction) -> String {
        let names = immediateTargets(for: action).map(\.name)
        guard !names.isEmpty else { return "没有可立即\(action.title)的 App" }
        return "立即\(action.title)：\(names.joined(separator: "、"))"
    }

    func performConfiguredApps(_ action: AutoAction) {
        let targets = immediateTargets(for: action)
        guard !targets.isEmpty else {
            statusMessage = "没有可立即\(action.title)的 App"
            return
        }

        let progress = BatchProgress(total: targets.count)
        statusMessage = "正在\(action.title) \(targets.count) 个 App…"

        for item in targets {
            perform(
                action,
                on: item.app,
                named: item.name,
                bundleIdentifier: item.bundleIdentifier,
                automatic: false
            ) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    progress.succeeded += 1
                } else {
                    progress.failed += 1
                }
                progress.remaining -= 1

                if progress.remaining == 0 {
                    if progress.failed == 0 {
                        self.statusMessage = "已\(action.title) \(progress.succeeded) 个 App"
                    } else {
                        self.statusMessage = "已\(action.title) \(progress.succeeded) 个，\(progress.failed) 个失败"
                    }
                }
            }
        }
    }

    func refreshApps() {
        let ownBundleID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                app.bundleIdentifier != ownBundleID &&
                app.localizedName != nil
            }
            .compactMap { app -> RunningAppItem? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: name) ?? NSImage()
                return RunningAppItem(
                    id: "\(bundleID)#\(app.processIdentifier)",
                    bundleIdentifier: bundleID,
                    processIdentifier: app.processIdentifier,
                    name: name,
                    icon: icon,
                    isHidden: app.isHidden,
                    isActive: app.isActive,
                    app: app
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let runningBundleIDs = Set(running.map(\.bundleIdentifier))
        let activeBundleIDs = Set(running.filter(\.isActive).map(\.bundleIdentifier))
        for bundleID in runningBundleIDs {
            if activeBundleIDs.contains(bundleID) {
                inactiveSince.removeValue(forKey: bundleID)
            } else if inactiveSince[bundleID] == nil {
                inactiveSince[bundleID] = effectiveNow
            }
        }
        inactiveSince = inactiveSince.filter { runningBundleIDs.contains($0.key) }
        alreadyHandled.formIntersection(runningBundleIDs)
        actionFailures = actionFailures.filter { runningBundleIDs.contains($0.key) }
        apps = running
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
            statusMessage = enabled ? "已设置登录时启动" : "已取消登录时启动"
        } catch {
            refreshLoginStatus()
            statusMessage = "登录项设置失败：请先把 QuitHide 移到“应用程序”文件夹"
        }
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            Task { @MainActor in
                self?.inactiveSince.removeValue(forKey: bundleID)
                self?.alreadyHandled.remove(bundleID)
                self?.actionFailures.removeValue(forKey: bundleID)
                self?.refreshApps()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self else { return }
                self.inactiveSince[bundleID] = self.effectiveNow
                self.alreadyHandled.remove(bundleID)
                self.actionFailures.removeValue(forKey: bundleID)
                self.refreshApps()
            }
        })

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshApps() }
            })
        }
    }

    private func installTimer() {
        let refreshTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleApps()
            }
        }
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
    }

    private func checkIdleApps() {
        refreshApps()
        guard automationEnabled else { return }

        let now = Date()

        for item in apps {
            let bundleID = item.bundleIdentifier
            let action = policy(for: bundleID)
            guard action.isAutomated,
                  !item.isActive,
                  !alreadyHandled.contains(bundleID),
                  let inactiveAt = inactiveSince[bundleID],
                  now.timeIntervalSince(inactiveAt) >= thresholdSeconds(for: bundleID) else { continue }

            perform(action, on: item.app, named: item.name, bundleIdentifier: bundleID, automatic: true)
        }
    }

    private func immediateTargets(for action: AutoAction) -> [RunningAppItem] {
        apps.filter { item in
            guard policy(for: item.bundleIdentifier) == action else { return false }
            if action == .hide {
                return !item.isHidden
            }
            return action == .quit
        }
    }

    private func perform(
        _ action: AutoAction,
        on app: NSRunningApplication,
        named name: String,
        bundleIdentifier: String,
        automatic: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        switch action {
        case .hide:
            _ = app.hide()
        case .quit:
            _ = app.terminate()
        case .unset, .ignore:
            return
        }

        alreadyHandled.insert(bundleIdentifier)
        actionFailures.removeValue(forKey: bundleIdentifier)
        statusMessage = "正在\(action.title)：\(name)"

        // NSRunningApplication actions are asynchronous on recent macOS versions.
        // Verify the resulting state instead of trusting the immediate return value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, app] in
            guard let self else { return }
            let succeeded: Bool
            switch action {
            case .hide:
                succeeded = app.isHidden || app.isTerminated
            case .quit:
                succeeded = app.isTerminated
            case .unset, .ignore:
                return
            }

            if succeeded {
                self.actionFailures.removeValue(forKey: bundleIdentifier)
                self.statusMessage = "\(automatic ? "自动" : "已")\(action.title)：\(name)"
                Self.logger.notice("Action succeeded: \(action.rawValue, privacy: .public) \(bundleIdentifier, privacy: .public) automatic=\(automatic, privacy: .public)")
            } else {
                self.actionFailures[bundleIdentifier] = action
                self.statusMessage = "无法\(action.title)：\(name)"
                Self.logger.error("Action failed: \(action.rawValue, privacy: .public) \(bundleIdentifier, privacy: .public) automatic=\(automatic, privacy: .public)")
            }
            completion?(succeeded)
            self.refreshApps()
        }
    }

    private func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var effectiveNow: Date {
        pauseStartedAt ?? Date()
    }

    private func thresholdSeconds(for bundleIdentifier: String) -> TimeInterval {
        if let testSeconds = ProcessInfo.processInfo.environment["QUITHIDE_TEST_IDLE_SECONDS"],
           let parsed = TimeInterval(testSeconds), parsed > 0 {
            return parsed
        }
        return TimeInterval(idleMinutes(for: bundleIdentifier) * 60)
    }

    private func formatRemainingTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(ceil(interval)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct AppRow: View {
    @EnvironmentObject private var model: AppModel
    let item: RunningAppItem

    private var action: AutoAction {
        model.policy(for: item.bundleIdentifier)
    }

    private var minuteOptions: [Int] {
        let presets = [1, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]
        return Array(Set(presets + [model.idleMinutes(for: item.bundleIdentifier)])).sorted()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if let status = model.automationStatus(for: item) {
                    Text(status.text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .help(status.text)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { model.policy(for: item.bundleIdentifier) },
                set: { model.setPolicy($0, for: item.bundleIdentifier) }
            )) {
                ForEach(AutoAction.allCases, id: \.self) { option in
                    Label {
                        Text(option.title)
                            .foregroundStyle(.primary)
                    } icon: {
                        ActionSymbol(action: option)
                    }
                    .tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 104)

            Group {
                if !action.isAutomated {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("未设置等待时间")
                } else {
                    Picker("等待时间", selection: Binding(
                        get: { model.idleMinutes(for: item.bundleIdentifier) },
                        set: { model.setIdleMinutes($0, for: item.bundleIdentifier) }
                    )) {
                        ForEach(minuteOptions, id: \.self) { minutes in
                            Text(durationTitle(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .help("离开前台多久后处理")
                }
            }
            .frame(width: 90)
        }
        .frame(minHeight: 40)
    }

    private func durationTitle(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
        return "\(minutes / 60)时\(minutes % 60)分"
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var updateState: UpdateViewState = .idle

    private enum UpdateViewState {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "版本 \(version)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("QuitHide 设置")
                    .font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Toggle("登录时启动", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Divider()

            Text("规则说明")
                .font(.headline)
            Text("每个 App 可分别设置离开前台后的等待时间和动作，重新激活后重新计时。\n隐藏：App 继续运行并隐藏窗口。\n退出：正常退出 App；未保存内容仍由 App 提醒。\n未设置：尚未选择规则。\n不处理：QuitHide 忽略该 App。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("关于 QuitHide")
                    .font(.headline)

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("作者：江sir爱数码")
                        Text("问题反馈微信：jsasm1")
                            .textSelection(.enabled)
                        Text(versionText)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    Spacer()

                    Button(updateButtonTitle) {
                        handleUpdateButton()
                    }
                    .disabled(isChecking)
                    .suppressFocusEffect()
                }

                if let statusText = updateStatusText {
                    HStack(spacing: 7) {
                        Image(systemName: updateStatusSymbol)
                            .foregroundStyle(updateStatusColor)

                        Text(statusText)
                            .foregroundStyle(.primary)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        updateStatusColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(updateStatusColor.opacity(0.22), lineWidth: 0.5)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Link(
                    "GitHub 项目",
                    destination: URL(string: "https://github.com/jiangsir-tech/QuitHide")!
                )
                .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 410)
    }

    private var isChecking: Bool {
        if case .checking = updateState { return true }
        return false
    }

    private var updateButtonTitle: String {
        if case .available = updateState { return "前往下载" }
        return isChecking ? "正在检查…" : "检查更新"
    }

    private var updateStatusText: String? {
        switch updateState {
        case .idle, .checking:
            return nil
        case .upToDate:
            return "当前已是最新版本"
        case let .available(update):
            return "发现新版本 \(update.version)"
        case .failed:
            return "检查失败，请稍后重试"
        }
    }

    private var updateStatusSymbol: String {
        switch updateState {
        case .upToDate:
            return "checkmark.circle.fill"
        case .available:
            return "arrow.up.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .idle, .checking:
            return "info.circle.fill"
        }
    }

    private var updateStatusColor: Color {
        switch updateState {
        case .upToDate:
            return .green
        case .available:
            return .blue
        case .failed:
            return .red
        case .idle, .checking:
            return .secondary
        }
    }

    private func handleUpdateButton() {
        if case let .available(update) = updateState {
            NSWorkspace.shared.open(update.downloadURL)
            return
        }

        updateState = .checking
        Task { @MainActor in
            do {
                switch try await UpdateChecker.check() {
                case .upToDate:
                    withAnimation(.easeOut(duration: 0.18)) {
                        updateState = .upToDate
                    }
                case let .updateAvailable(update):
                    withAnimation(.easeOut(duration: 0.18)) {
                        updateState = .available(update)
                    }
                }
            } catch {
                withAnimation(.easeOut(duration: 0.18)) {
                    updateState = .failed
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func suppressFocusEffect() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var ignoredExpanded = false

    private var automatedApps: [RunningAppItem] {
        model.filteredApps.filter { model.policy(for: $0.bundleIdentifier).isAutomated }
    }

    private var unconfiguredApps: [RunningAppItem] {
        model.filteredApps.filter { model.policy(for: $0.bundleIdentifier) == .unset }
    }

    private var ignoredApps: [RunningAppItem] {
        model.filteredApps.filter { model.policy(for: $0.bundleIdentifier) == .ignore }
    }

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsIgnoredApps: Bool {
        ignoredExpanded || isSearching
    }

    private var visibleSectionCount: Int {
        [automatedApps, unconfiguredApps, ignoredApps].filter { !$0.isEmpty }.count
    }

    private var visibleRowCount: Int {
        automatedApps.count + unconfiguredApps.count + (showsIgnoredApps ? ignoredApps.count : 0)
    }

    private var menuHeight: CGFloat {
        let contentHeight = 220 + CGFloat(visibleRowCount * 40) + CGFloat(visibleSectionCount * 24)
        return min(max(contentHeight, 350), 620)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("QuitHide")
                        .font(.system(size: 20, weight: .semibold))
                    Text("按设定时间隐藏或退出 App")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(model.automationEnabled ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.automationEnabled ? "运行中" : "已暂停")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Button {
                    model.automationEnabled.toggle()
                } label: {
                    Image(systemName: model.automationEnabled ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.automationEnabled ? Color.secondary : Color.orange)
                        .frame(width: 28, height: 28)
                        .background(
                            Color.primary.opacity(0.07),
                            in: Circle()
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.automationEnabled ? "暂停自动处理" : "继续自动处理")

                Button {
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
            }
            .padding(16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索运行中的 App", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if model.filteredApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("没有匹配的 App")
                        .foregroundStyle(.secondary)
                }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !automatedApps.isEmpty {
                            sectionHeader("自动处理", count: automatedApps.count)
                            appRows(automatedApps)
                        }

                        if !unconfiguredApps.isEmpty {
                            sectionHeader("待设置", count: unconfiguredApps.count)
                            appRows(unconfiguredApps)
                        }

                        if !ignoredApps.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    ignoredExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: showsIgnoredApps ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("不处理（\(ignoredApps.count)）")
                                    Spacer()
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showsIgnoredApps {
                                appRows(ignoredApps)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 9)
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Text("提前执行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        model.performConfiguredApps(.hide)
                    } label: {
                        HStack(spacing: 6) {
                            ActionSymbol(action: .hide)
                            Text("立即隐藏（\(model.immediateTargetCount(for: .hide))）")
                                .foregroundStyle(.primary)
                        }
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .disabled(model.immediateTargetCount(for: .hide) == 0)
                    .help(model.immediateTargetHelp(for: .hide))

                    Button {
                        model.performConfiguredApps(.quit)
                    } label: {
                        HStack(spacing: 6) {
                            ActionSymbol(action: .quit)
                            Text("立即退出（\(model.immediateTargetCount(for: .quit))）")
                                .foregroundStyle(.primary)
                        }
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .disabled(model.immediateTargetCount(for: .quit) == 0)
                    .help(model.immediateTargetHelp(for: .quit))
                }

                HStack {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("退出 QuitHide") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 410, height: menuHeight)
        .animation(.easeInOut(duration: 0.16), value: menuHeight)
        .onAppear { model.refreshApps() }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text("\(title)（\(count)）")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func appRows(_ items: [RunningAppItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            AppRow(item: item)
            if index < items.count - 1 {
                Divider()
                    .opacity(0.55)
                    .padding(.leading, 38)
            }
        }
    }
}

@main
struct QuitHideApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Label("QuitHide", systemImage: "rectangle.on.rectangle.slash")
        }
        .menuBarExtraStyle(.window)

        Window("QuitHide 设置", id: "settings") {
            SettingsSheet()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
