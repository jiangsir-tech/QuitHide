import Foundation
import Testing
@testable import QuitHide

@Suite("Update checker network fallback", .serialized)
struct UpdateNetworkTests {
    private let endpoints = UpdateEndpoints(
        manifestURL: URL(string: "https://updates.example/main/update.json")!,
        releasesURL: URL(string: "https://api.example/releases")!,
        taggedManifestBaseURL: URL(string: "https://updates.example/tags/")!
    )

    @Test("Fallback excludes prereleases and verifies the stable tag manifest")
    func excludesPrereleasesAndLoadsTaggedManifest() async throws {
        let session = makeSession { request in
            switch request.url?.absoluteString {
            case "https://updates.example/main/update.json":
                return Self.response(for: request, status: 503, json: [:])
            case "https://api.example/releases":
                return Self.response(for: request, json: [
                    ["tag_name": "v0.4.0-beta.1", "draft": false, "prerelease": true],
                    ["tag_name": "v0.3.0", "draft": false, "prerelease": false]
                ])
            case "https://updates.example/tags/v0.3.0/update.json":
                return Self.response(for: request, json: Self.manifest(
                    version: "0.3.0",
                    build: 10,
                    minimumSystemVersion: "13.0"
                ))
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { session.invalidateAndCancel() }

        let result = try await UpdateChecker.check(
            currentVersionString: "0.2.4",
            currentBuild: 9,
            currentSystemVersion: try #require(MacOSVersion("13.0")),
            session: session,
            endpoints: endpoints
        )
        guard case let .updateAvailable(update) = result else {
            Issue.record("The stable fallback release should be available")
            return
        }
        #expect(update.version == "0.3.0")
        #expect(update.build == 10)
        #expect(update.minimumSystemVersion == "13.0")
    }

    @Test("Fallback refuses a release when its tagged compatibility manifest is unavailable")
    func refusesUnknownFallbackCompatibility() async throws {
        let session = makeSession { request in
            switch request.url?.absoluteString {
            case "https://updates.example/main/update.json":
                return Self.response(for: request, status: 503, json: [:])
            case "https://api.example/releases":
                return Self.response(for: request, json: [
                    ["tag_name": "v0.3.0", "draft": false, "prerelease": false]
                ])
            case "https://updates.example/tags/v0.3.0/update.json":
                return Self.response(for: request, status: 404, json: [:])
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await UpdateChecker.check(
                currentVersionString: "0.2.4",
                currentBuild: 9,
                currentSystemVersion: try #require(MacOSVersion("13.0")),
                session: session,
                endpoints: endpoints
            )
            Issue.record("Unknown compatibility must not produce an update")
        } catch {
            #expect(error is URLError || error is UpdateCheckError)
        }
    }

    @Test("A valid but incompatible main manifest is not offered and does not fall back")
    func blocksIncompatibleManifest() async throws {
        let session = makeSession { request in
            guard request.url?.absoluteString == "https://updates.example/main/update.json" else {
                throw URLError(.unsupportedURL)
            }
            return Self.response(for: request, json: Self.manifest(
                version: "0.3.0",
                build: 10,
                minimumSystemVersion: "14.0"
            ))
        }
        defer { session.invalidateAndCancel() }

        let result = try await UpdateChecker.check(
            currentVersionString: "0.2.4",
            currentBuild: 9,
            currentSystemVersion: try #require(MacOSVersion("13.6")),
            session: session,
            endpoints: endpoints
        )
        #expect(result == .upToDate)
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        UpdateTestURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        json: Any
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, try! JSONSerialization.data(withJSONObject: json))
    }

    private static func manifest(
        version: String,
        build: Int,
        minimumSystemVersion: String
    ) -> [String: Any] {
        [
            "version": version,
            "build": build,
            "minimumSystemVersion": minimumSystemVersion,
            "releaseNotes": "Test release",
            "downloadURL": "https://github.com/jiangsir-tech/QuitHide/releases/tag/v\(version)"
        ]
    }
}

private final class UpdateTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func install(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        do {
            guard let handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
