import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Requisição HTTP genérica.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Tempo limite desta requisição (segundos). `nil` usa o padrão da sessão.
    public var timeout: TimeInterval?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// Abstração mínima de HTTP para permitir testes sem rede.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

extension HTTPClient {
    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(HTTPRequest(url: url, headers: headers))
    }

    public func post(_ url: URL, json: Data, headers: [String: String] = [:]) async throws -> HTTPResponse {
        var h = headers
        h["Content-Type"] = "application/json"
        return try await send(HTTPRequest(method: "POST", url: url, headers: h, body: json))
    }
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

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Política de destino das requisições.
public enum RequestPolicy: Sendable, Equatable {
    /// Qualquer host, somente HTTPS (fontes online e catálogo).
    case httpsOnly
    /// HTTPS ou HTTP. Só para clientes que validam o destino por conta própria
    /// (ex.: o catálogo de repositórios, que aceita HTTP apenas quando o
    /// usuário habilita explicitamente para aquele repositório).
    case httpsOrHTTP
    /// Somente o servidor pessoal configurado (mesmo esquema, host e porta).
    /// HTTP só é aceito se `allowHTTP` for verdadeiro (rede local).
    case personalServer(base: URL, allowHTTP: Bool)

    public func validate(_ url: URL) throws {
        switch self {
        case .httpsOnly:
            try URLPolicy.validateRemote(url)
        case .httpsOrHTTP:
            try URLPolicy.validatePersonalServer(url, allowInsecureHTTP: true)
        case .personalServer(let base, let allowHTTP):
            try URLPolicy.validatePersonalServer(url, allowInsecureHTTP: allowHTTP)
            guard url.host?.lowercased() == base.host?.lowercased(),
                  (url.port ?? Self.defaultPort(url)) == (base.port ?? Self.defaultPort(base)) else {
                throw FYError.insecureURL("destino fora do servidor configurado: \(Redactor.redact(url))")
            }
        }
    }

    static func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }
}

/// Implementação com `URLSession`, com validação de destino (inclusive após
/// redirecionamentos), limite de tamanho e mensagens de erro compreensíveis.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let maxBytes: Int
    private let policy: RequestPolicy
    /// Cabeçalhos acrescentados a todas as requisições (ex.: autenticação do servidor pessoal).
    private let defaultHeaders: [String: String]

    public static let userAgent = "FreeYomi/0.5 (leitor de mangás open source)"

    /// Sessão compartilhada e efêmera (sem cookies nem cache HTTP).
    /// É mantida viva durante todo o processo: além de reaproveitar conexões,
    /// isso evita uma falha conhecida do FoundationNetworking no Linux ao
    /// desalocar `URLSession`.
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = URLSessionHTTPClient.sharedSession, maxBytes: Int = 32 * 1024 * 1024,
                policy: RequestPolicy = .httpsOnly, defaultHeaders: [String: String] = [:]) {
        self.session = session
        self.maxBytes = maxBytes
        self.policy = policy
        self.defaultHeaders = defaultHeaders
    }

    public func send(_ req: HTTPRequest) async throws -> HTTPResponse {
        try policy.validate(req.url)
        var request = URLRequest(url: req.url)
        request.httpMethod = req.method
        request.httpBody = req.body
        if let timeout = req.timeout { request.timeoutInterval = timeout }
        for (k, v) in defaultHeaders { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in req.headers { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw FYError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw FYError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw FYError.network("tempo limite esgotado")
        } catch {
            throw FYError.network((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FYError.invalidData("resposta não-HTTP")
        }
        if let final = http.url { try policy.validate(final) }
        guard data.count <= maxBytes else {
            throw FYError.invalidData("resposta maior que \(maxBytes / 1024 / 1024) MB")
        }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { hdrs[k.lowercased()] = v }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: hdrs, body: data, finalURL: http.url)
    }

    /// Cabeçalho `Authorization: Basic …`.
    public static func basicAuth(user: String, password: String) -> [String: String] {
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }
}

/// Limitador simples de taxa (intervalo mínimo entre requisições), para
/// respeitar os limites das APIs públicas.
public actor RateLimiter {
    private let minInterval: TimeInterval
    private var next = Date.distantPast

    public init(requestsPerSecond: Double) {
        minInterval = 1 / max(requestsPerSecond, 0.01)
    }

    public func wait() async throws {
        let now = Date()
        let slot = max(now, next)
        next = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}
