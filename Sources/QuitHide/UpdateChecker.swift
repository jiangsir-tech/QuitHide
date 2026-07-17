import Foundation

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ rawValue: String) {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("v") {
            normalized.removeFirst()
        }

        let versionParts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(coreParts.count),
              let major = Int(coreParts[0]),
              coreParts.count < 2 || Int(coreParts[1]) != nil,
              coreParts.count < 3 || Int(coreParts[2]) != nil else { return nil }

        self.major = major
        minor = coreParts.count > 1 ? Int(coreParts[1])! : 0
        patch = coreParts.count > 2 ? Int(coreParts[2])! : 0
        prerelease = versionParts.count > 1 && !versionParts[1].isEmpty
            ? String(versionParts[1])
            : nil
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
            return lhsValue.compare(rhsValue, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }
}

struct AvailableUpdate: Equatable {
    let version: String
    let build: Int?
    let releaseNotes: String
    let downloadURL: URL
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

enum UpdateChecker {
    private static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/1551255004/QuitHide/main/update.json"
    )!
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/1551255004/QuitHide/releases?per_page=20"
    )!

    private struct UpdateManifest: Decodable {
        let version: String
        let build: Int
        let releaseNotes: String
        let downloadURL: URL
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case draft
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

        do {
            let manifest: UpdateManifest = try await fetch(
                UpdateManifest.self,
                from: manifestURL,
                session: session
            )
            if manifest.build > currentBuild {
                return .updateAvailable(AvailableUpdate(
                    version: manifest.version,
                    build: manifest.build,
                    releaseNotes: manifest.releaseNotes,
                    downloadURL: manifest.downloadURL
                ))
            }
            return .upToDate
        } catch {
            return try await checkGitHubReleases(
                currentVersionString: currentVersionString,
                session: session
            )
        }
    }

    private static func checkGitHubReleases(
        currentVersionString: String,
        session: URLSession
    ) async throws -> UpdateCheckResult {
        let releases: [GitHubRelease] = try await fetch(
            [GitHubRelease].self,
            from: releasesURL,
            session: session
        )
        let candidates = releases.compactMap { release -> (GitHubRelease, SemanticVersion)? in
            guard !release.draft, let version = SemanticVersion(release.tagName) else { return nil }
            return (release, version)
        }
        guard let latest = candidates.max(by: { $0.1 < $1.1 }) else {
            throw UpdateCheckError.noRelease
        }

        guard let currentVersion = SemanticVersion(currentVersionString),
              currentVersion < latest.1 else {
            return .upToDate
        }

        let cleanVersion = latest.0.tagName.hasPrefix("v")
            ? String(latest.0.tagName.dropFirst())
            : latest.0.tagName
        return .updateAvailable(AvailableUpdate(
            version: cleanVersion,
            build: nil,
            releaseNotes: latest.0.body ?? latest.0.name ?? "",
            downloadURL: latest.0.htmlURL
        ))
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
              (200...299).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.invalidResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
