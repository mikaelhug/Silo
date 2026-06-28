import Foundation

/// Intercepts URLSession requests and serves canned responses for tests (works for both
/// `data(from:)` and `download(from:)`). Safe under Swift 6: the static registry is lock-guarded.
///
/// Stubs are keyed by URL string in a process-wide registry shared across the parallel suite, so a
/// test that stubs a URL should use a UNIQUE url string. When the URL is fixed (e.g. a production
/// constant like `Silo.steamInstallerURL`) and two tests must stub it with *different* responses,
/// register the stub **scoped to a session** via `stub(_:session:…)` + the matching `makeSession()`:
/// scoped stubs are isolated per session and take precedence over the global registry, so concurrent
/// tests don't clobber each other.
final class FakeURLProtocol: URLProtocol {
    struct Stub: Sendable { let statusCode: Int; let data: Data }

    /// Header used to carry a session's isolation token on every request it makes.
    private static let sessionHeader = "X-FakeURLProtocol-Session"

    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var scopedStubs: [String: [String: Stub]] = [:]   // [sessionID: [url: Stub]]
    private static let lock = NSLock()

    /// Register a stub in the process-wide registry (use a UNIQUE url per test).
    static func stub(_ url: String, statusCode: Int = 200, data: Data) {
        lock.withLock { stubs[url] = Stub(statusCode: statusCode, data: data) }
    }

    /// Register a stub visible only to requests made by `session` (built via the `session:`-returning
    /// `makeSession()`). Use this when the URL is fixed and another test stubs it differently.
    static func stub(_ url: String, statusCode: Int = 200, data: Data, session: URLSession) {
        guard let id = sessionID(of: session) else {
            return stub(url, statusCode: statusCode, data: data)
        }
        lock.withLock { scopedStubs[id, default: [:]][url] = Stub(statusCode: statusCode, data: data) }
    }

    private static func stub(for url: URL, sessionID: String?) -> Stub? {
        lock.withLock {
            if let id = sessionID, let scoped = scopedStubs[id]?[url.absoluteString] { return scoped }
            return stubs[url.absoluteString]
        }
    }

    /// A URLSession wired to use this protocol exclusively. Each session carries a unique isolation
    /// token so `stub(_:session:)` can scope responses to it.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeURLProtocol.self]
        config.httpAdditionalHeaders = [sessionHeader: UUID().uuidString]
        return URLSession(configuration: config)
    }

    private static func sessionID(of session: URLSession) -> String? {
        session.configuration.httpAdditionalHeaders?[sessionHeader] as? String
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader)
        guard let url = request.url, let stub = Self.stub(for: url, sessionID: sessionID) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
