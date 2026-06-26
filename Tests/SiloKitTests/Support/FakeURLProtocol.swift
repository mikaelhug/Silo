import Foundation

/// Intercepts URLSession requests and serves canned responses for tests (works for both
/// `data(from:)` and `download(from:)`). Safe under Swift 6: the static registry is lock-guarded.
final class FakeURLProtocol: URLProtocol {
    struct Stub: Sendable { let statusCode: Int; let data: Data }

    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    private static let lock = NSLock()

    static func stub(_ url: String, statusCode: Int = 200, data: Data) {
        lock.withLock { stubs[url] = Stub(statusCode: statusCode, data: data) }
    }

    static func reset() { lock.withLock { stubs.removeAll() } }

    private static func stub(for url: URL) -> Stub? {
        lock.withLock { stubs[url.absoluteString] }
    }

    /// A URLSession wired to use this protocol exclusively.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url) else {
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
