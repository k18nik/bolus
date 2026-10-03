import Foundation

/// Platform-neutral HTTP request description. The app maps it to `URLRequest`
/// (URLSession, redirects disabled); tests use an in-memory transport.
public struct HTTPRequestSpec: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponseData: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Transport used by external integrations only (food catalogs, AI). Throws on
/// connectivity problems; core features never call it.
public typealias HTTPTransport = @Sendable (HTTPRequestSpec) async throws -> HTTPResponseData
