import Foundation

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ rawValue: String) {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let metadataParts = normalized.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !metadataParts[0].isEmpty,
              metadataParts.count == 1 || Self.validIdentifiers(
                  String(metadataParts[1]),
                  rejectNumericLeadingZeroes: false
              ) else { return nil }

        let versionParts = metadataParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let coreParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3,
              let major = Self.strictCoreNumber(coreParts[0]),
              let minor = Self.strictCoreNumber(coreParts[1]),
              let patch = Self.strictCoreNumber(coreParts[2]) else { return nil }

        let prerelease = versionParts.count == 2 ? String(versionParts[1]) : nil
        guard prerelease == nil || Self.validIdentifiers(
            prerelease!,
            rejectNumericLeadingZeroes: true
        ) else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var normalizedString: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(lhsValue), .some(rhsValue)):
            return comparePrerelease(lhsValue, rhsValue) == .orderedAscending
        }
    }

    private static func strictCoreNumber(_ value: Substring) -> Int? {
        guard isASCIIDigits(value),
              value.count == 1 || value.first != "0" else { return nil }
        return Int(value)
    }

    private static func validIdentifiers(
        _ value: String,
        rejectNumericLeadingZeroes: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }

        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 45, 48...57, 65...90, 97...122:
                          return true
                      default:
                          return false
                      }
                  }) else { return false }

            if rejectNumericLeadingZeroes,
               isASCIIDigits(identifier),
               identifier.count > 1,
               identifier.first == "0" {
                return false
            }
            return true
        }
    }

    private static func isASCIIDigits(_ value: some StringProtocol) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let rhsParts = rhs.split(separator: ".", omittingEmptySubsequences: false)

        for index in 0..<min(lhsParts.count, rhsParts.count) {
            let lhsPart = lhsParts[index]
            let rhsPart = rhsParts[index]
            if lhsPart == rhsPart { continue }

            let lhsIsNumeric = isASCIIDigits(lhsPart)
            let rhsIsNumeric = isASCIIDigits(rhsPart)
            switch (lhsIsNumeric, rhsIsNumeric) {
            case (true, true):
                if lhsPart.count != rhsPart.count {
                    return lhsPart.count < rhsPart.count ? .orderedAscending : .orderedDescending
                }
                return lhsPart.lexicographicallyPrecedes(rhsPart)
                    ? .orderedAscending
                    : .orderedDescending
            case (true, false):
                return .orderedAscending
            case (false, true):
                return .orderedDescending
            case (false, false):
                return lhsPart.lexicographicallyPrecedes(rhsPart)
                    ? .orderedAscending
                    : .orderedDescending
            }
        }

        if lhsParts.count == rhsParts.count { return .orderedSame }
        return lhsParts.count < rhsParts.count ? .orderedAscending : .orderedDescending
    }
}

struct MacOSVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let parts = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ part in
                  !part.isEmpty && part.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
              }) else { return nil }

        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    init(_ version: OperatingSystemVersion) {
        major = version.majorVersion
        minor = version.minorVersion
        patch = version.patchVersion
    }

    static func < (lhs: MacOSVersion, rhs: MacOSVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct AvailableUpdate: Codable, Equatable {
    let version: String
    let build: Int?
    let minimumSystemVersion: String?
    let releaseNotes: String
    let downloadURL: URL

    init(
        version: String,
        build: Int?,
        minimumSystemVersion: String? = nil,
        releaseNotes: String,
        downloadURL: URL
    ) {
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotes = releaseNotes
        self.downloadURL = downloadURL
    }

    var reminderIdentity: UpdateReleaseIdentity {
        UpdateReleaseIdentity(version: version, build: build)
    }
}

enum UpdateCheckResult: Equatable {
    case upToDate
    case updateAvailable(AvailableUpdate)
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case noRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "更新服务器返回了无效响应"
        case .noRelease:
            return "暂未找到可用版本"
        }
    }
}

struct UpdateEndpoints {
    let manifestURL: URL
    let releasesURL: URL
    let taggedManifestBaseURL: URL

    static let production = UpdateEndpoints(
        manifestURL: URL(
            string: "https://raw.githubusercontent.com/jiangsir-tech/QuitHide/main/update.json"
        )!,
        releasesURL: URL(
            string: "https://api.github.com/repos/jiangsir-tech/QuitHide/releases?per_page=20"
        )!,
        taggedManifestBaseURL: URL(
            string: "https://raw.githubusercontent.com/jiangsir-tech/QuitHide/"
        )!
    )

    func taggedManifestURL(for tagName: String) -> URL? {
        guard !tagName.isEmpty,
              tagName.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 43, 45...46, 48...57, 65...90, 95, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else { return nil }
        return taggedManifestBaseURL
            .appendingPathComponent(tagName, isDirectory: true)
            .appendingPathComponent("update.json", isDirectory: false)
    }
}

enum UpdateChecker {
    private static let maximumResponseBytes = 1_048_576

    private struct UpdateManifest: Decodable {
        let version: String
        let build: Int
        let minimumSystemVersion: String
        let releaseNotes: String
        let downloadURL: URL
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
        }
    }

    static func check(
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) async throws -> UpdateCheckResult {
        let currentVersionString = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        let currentBuild = Int(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        ) ?? 0
        return try await check(
            currentVersionString: currentVersionString,
            currentBuild: currentBuild,
            currentSystemVersion: MacOSVersion(ProcessInfo.processInfo.operatingSystemVersion),
            session: session,
            endpoints: .production
        )
    }

    static func check(
        currentVersionString: String,
        currentBuild: Int,
        currentSystemVersion: MacOSVersion,
        session: URLSession,
        endpoints: UpdateEndpoints
    ) async throws -> UpdateCheckResult {
        guard let currentVersion = SemanticVersion(currentVersionString) else {
            throw UpdateCheckError.invalidResponse
        }

        do {
            let manifest: UpdateManifest = try await fetch(
                UpdateManifest.self,
                from: endpoints.manifestURL,
                session: session
            )
            return try result(
                for: manifest,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                currentSystemVersion: currentSystemVersion
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return try await checkGitHubReleases(
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                currentSystemVersion: currentSystemVersion,
                session: session,
                endpoints: endpoints
            )
        }
    }

    static func isUpdateNewer(
        currentVersion: SemanticVersion,
        currentBuild: Int,
        availableVersion: SemanticVersion,
        availableBuild: Int
    ) -> Bool {
        if currentVersion != availableVersion {
            return currentVersion < availableVersion
        }
        return availableBuild > currentBuild
    }

    static func isUpdateNewer(
        _ update: AvailableUpdate,
        than bundle: Bundle = .main
    ) -> Bool {
        let currentVersionString = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        let currentBuild = Int(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        ) ?? 0
        guard let currentVersion = SemanticVersion(currentVersionString),
              let availableVersion = SemanticVersion(update.version) else {
            return false
        }
        guard let availableBuild = update.build else {
            return currentVersion < availableVersion
        }
        return isUpdateNewer(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            availableVersion: availableVersion,
            availableBuild: availableBuild
        )
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil else { return false }

        let expectedRoot = "/jiangsir-tech/QuitHide/releases"
        return url.path == expectedRoot || url.path.hasPrefix(expectedRoot + "/")
    }

    static func validatedAvailableUpdate(
        _ update: AvailableUpdate,
        currentSystemVersion: MacOSVersion = MacOSVersion(
            ProcessInfo.processInfo.operatingSystemVersion
        )
    ) -> AvailableUpdate? {
        guard let availableVersion = SemanticVersion(update.version),
              update.build.map({ $0 >= 0 }) ?? true,
              let minimumSystemVersionString = update.minimumSystemVersion,
              let minimumSystemVersion = MacOSVersion(minimumSystemVersionString),
              minimumSystemVersion <= currentSystemVersion,
              isAllowedDownloadURL(update.downloadURL) else { return nil }

        return AvailableUpdate(
            version: availableVersion.normalizedString,
            build: update.build,
            minimumSystemVersion: minimumSystemVersionString,
            releaseNotes: update.releaseNotes,
            downloadURL: update.downloadURL
        )
    }

    private static func result(
        for manifest: UpdateManifest,
        currentVersion: SemanticVersion,
        currentBuild: Int,
        currentSystemVersion: MacOSVersion
    ) throws -> UpdateCheckResult {
        guard let availableVersion = SemanticVersion(manifest.version),
              manifest.build >= 0,
              let minimumSystemVersion = MacOSVersion(manifest.minimumSystemVersion),
              isAllowedDownloadURL(manifest.downloadURL) else {
            throw UpdateCheckError.invalidResponse
        }
        guard minimumSystemVersion <= currentSystemVersion else {
            return .upToDate
        }
        guard isUpdateNewer(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            availableVersion: availableVersion,
            availableBuild: manifest.build
        ) else {
            return .upToDate
        }

        return .updateAvailable(AvailableUpdate(
            version: availableVersion.normalizedString,
            build: manifest.build,
            minimumSystemVersion: manifest.minimumSystemVersion,
            releaseNotes: manifest.releaseNotes,
            downloadURL: manifest.downloadURL
        ))
    }

    private static func checkGitHubReleases(
        currentVersion: SemanticVersion,
        currentBuild: Int,
        currentSystemVersion: MacOSVersion,
        session: URLSession,
        endpoints: UpdateEndpoints
    ) async throws -> UpdateCheckResult {
        let releases: [GitHubRelease] = try await fetch(
            [GitHubRelease].self,
            from: endpoints.releasesURL,
            session: session
        )
        let candidates = releases.compactMap { release -> (GitHubRelease, SemanticVersion)? in
            guard !release.draft,
                  !release.prerelease,
                  let version = SemanticVersion(release.tagName) else { return nil }
            return (release, version)
        }
        guard let latest = candidates.max(by: { $0.1 < $1.1 }) else {
            throw UpdateCheckError.noRelease
        }
        guard !(latest.1 < currentVersion) else {
            return .upToDate
        }
        guard let taggedManifestURL = endpoints.taggedManifestURL(for: latest.0.tagName) else {
            throw UpdateCheckError.invalidResponse
        }

        let manifest: UpdateManifest = try await fetch(
            UpdateManifest.self,
            from: taggedManifestURL,
            session: session
        )
        guard SemanticVersion(manifest.version) == latest.1 else {
            throw UpdateCheckError.invalidResponse
        }
        return try result(
            for: manifest,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            currentSystemVersion: currentSystemVersion
        )
    }

    private static func fetch<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        session: URLSession
    ) async throws -> Value {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuitHide-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url?.scheme?.lowercased() == "https",
              (200...299).contains(httpResponse.statusCode),
              data.count <= maximumResponseBytes else {
            throw UpdateCheckError.invalidResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
