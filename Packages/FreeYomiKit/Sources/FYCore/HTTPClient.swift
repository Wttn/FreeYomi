import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstração mínima de HTTP para permitir testes sem rede.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    /// URL final após redirecionamentos.
    public let finalURL: URL?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data, finalURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

/// Implementação com `URLSession`, com validação de HTTPS (inclusive após
/// redirecionamentos), limite de tamanho e mensagens de erro compreensíveis.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let maxBytes: Int

    /// Sessão compartilhada e efêmera (sem cookies nem cache HTTP).
    /// É mantida viva durante todo o processo: além de reaproveitar conexões,
    /// isso evita uma falha conhecida do FoundationNetworking no Linux ao
    /// desalocar `URLSession`.
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "FreeYomi/0.1 (open source manga reader)"]
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = URLSessionHTTPClient.sharedSession, maxBytes: Int = 32 * 1024 * 1024) {
        self.session = session
        self.maxBytes = maxBytes
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try URLPolicy.validateRemote(url)
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw FYError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw FYError.cancelled
        } catch {
            throw FYError.network((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FYError.invalidData("resposta não-HTTP")
        }
        if let final = http.url { try URLPolicy.validateRemote(final) }
        guard data.count <= maxBytes else {
            throw FYError.invalidData("resposta maior que \(maxBytes / 1024 / 1024) MB")
        }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { hdrs[k.lowercased()] = v }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: hdrs, body: data, finalURL: http.url)
    }
}
