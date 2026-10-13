import Foundation

/// Remove credenciais e parâmetros sensíveis de URLs antes de registrá-las
/// em logs ou mensagens de erro.
public enum Redactor {
    static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "api_key", "apikey", "key", "password", "pass", "auth", "session", "sig", "signature",
    ]

    public static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<url inválida>"
        }
        if components.user != nil || components.password != nil {
            components.user = "***"
            components.password = nil
        }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                sensitiveQueryKeys.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: "***")
                    : item
            }
        }
        return components.string ?? "<url inválida>"
    }

    public static func redact(_ string: String) -> String {
        guard let url = URL(string: string) else { return string }
        return redact(url)
    }
}

/// Validação de URLs externas.
public enum URLPolicy {
    /// Aceita apenas `https://` com host não vazio. Usado para catálogos e fontes online.
    public static func validateRemote(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw FYError.insecureURL(Redactor.redact(url))
        }
    }

    /// Servidores pessoais (ex.: Komga na rede local) podem usar HTTP explícito
    /// quando o usuário permitir; o padrão continua sendo HTTPS.
    public static func validatePersonalServer(_ url: URL, allowInsecureHTTP: Bool) throws {
        let scheme = url.scheme?.lowercased()
        guard let host = url.host, !host.isEmpty else { throw FYError.insecureURL(Redactor.redact(url)) }
        _ = host
        if scheme == "https" { return }
        if scheme == "http" && allowInsecureHTTP { return }
        throw FYError.insecureURL(Redactor.redact(url))
    }
}

/// Sanitização de nomes de arquivos e caminhos relativos (proteção contra
/// "zip slip" na importação de CBZ/ZIP — Fase 2).
public enum PathSanitizer {
    /// Retorna um caminho relativo seguro ou `nil` se o caminho tentar sair
    /// do diretório de destino (`..`, absoluto, vazio).
    public static func safeRelativePath(_ raw: String) -> String? {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") { return nil }
        var parts: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            if component.contains("\0") { return nil }
            parts.append(String(component))
        }
        if parts.isEmpty { return nil }
        if let first = parts.first, first.count == 2, first.hasSuffix(":") { return nil } // C:
        return parts.joined(separator: "/")
    }
}
