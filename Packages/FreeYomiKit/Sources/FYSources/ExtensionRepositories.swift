import Foundation
import FYCore

/// Um repositório de extensões (índice `index.pb` ou `repo.json`), como na tela
/// "Repositórios de extensões" do Mihon/Tachimanga.
///
/// Os dados vêm do próprio índice (nome, selo, site, Discord, chave de
/// assinatura) ou, com servidor conectado, da consulta `extensionStores` do
/// Suwayomi-Server, que guarda exatamente os mesmos campos.
public struct ExtensionRepository: Sendable, Codable, Hashable, Identifiable {
    public var indexURL: String
    public var name: String
    public var badgeLabel: String
    public var website: String?
    public var discord: String?
    public var signingKey: String?
    public var extensionCount: Int?
    public var id: String { indexURL }

    public init(indexURL: String, name: String, badgeLabel: String = "", website: String? = nil,
                discord: String? = nil, signingKey: String? = nil, extensionCount: Int? = nil) {
        self.indexURL = indexURL
        self.name = name
        self.badgeLabel = badgeLabel
        self.website = website
        self.discord = discord
        self.signingKey = signingKey
        self.extensionCount = extensionCount
    }

    public init(indexURL: String, index: ExtensionStoreIndex) {
        self.init(indexURL: indexURL, name: index.name, badgeLabel: index.badgeLabel,
                  website: index.website.isEmpty ? nil : index.website,
                  discord: (index.discord?.isEmpty ?? true) ? nil : index.discord,
                  signingKey: index.signingKey.isEmpty ? nil : index.signingKey,
                  extensionCount: index.extensions.count)
    }

    /// Impressão digital curta da chave de assinatura (para conferência visual).
    public var signingKeyFingerprint: String? {
        guard let k = signingKey, k.count >= 16 else { return nil }
        return stride(from: 0, to: 16, by: 4).map { i -> String in
            let a = k.index(k.startIndex, offsetBy: i)
            return String(k[a..<k.index(a, offsetBy: 4)])
        }.joined(separator: " ").uppercased()
    }

    /// Links de contato válidos (só HTTPS).
    public var websiteURL: URL? { Self.safeURL(website) }
    public var discordURL: URL? { Self.safeURL(discord) }

    static func safeURL(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Repositório padrão (o mesmo usado pelo Mihon).
    public static let keiyoushiURL = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"
}

/// Sugestões exibidas em "Encontrar repositório". São só atalhos para o
/// campo de endereço; nada é adicionado sem a confirmação do usuário, e o
/// índice é validado antes de entrar na lista.
public struct RepositorySuggestion: Sendable, Hashable, Identifiable {
    public let name: String
    public let indexURL: String
    public let note: String
    public var id: String { indexURL }

    public static let all: [RepositorySuggestion] = [
        RepositorySuggestion(name: "Keiyoushi", indexURL: ExtensionRepository.keiyoushiURL,
                             note: "Repositório comunitário principal, com fontes em vários idiomas."),
        RepositorySuggestion(name: "FelipeGFA", indexURL: "https://github.com/FelipeGFA/extensoes/raw/repo/index.pb",
                             note: "Repositório comunitário (selo FGFA) com fontes em vários idiomas, incluindo pt-BR."),
    ]
}

/// Erro no endereço digitado pelo usuário (mensagem pronta para exibir).
public struct RepositoryInputError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let alreadyAdded = RepositoryInputError("Este repositório já está na lista.")
}

public enum RepositoryURL {
    /// Valida e normaliza o que o usuário digitou ou colou. Aceita só HTTPS.
    /// Sem esquema, assume `https://`.
    public static func normalize(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RepositoryInputError("Informe o endereço do repositório.") }
        if !text.contains("://") { text = "https://" + text }
        guard let comps = URLComponents(string: text), let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else {
            throw RepositoryInputError("Endereço de repositório inválido.")
        }
        guard scheme == "https" else {
            throw RepositoryInputError("Use um endereço HTTPS. Repositórios em HTTP são recusados por segurança.")
        }
        guard comps.path.count > 1 else {
            throw RepositoryInputError("Informe o endereço completo do índice (termina em index.pb ou repo.json).")
        }
        if comps.path.hasSuffix("/index.min.json") {
            throw RepositoryInputError("index.min.json é o formato antigo. Use o endereço do repo.json ou do index.pb.")
        }
        var out = comps
        out.scheme = "https"
        out.host = host.lowercased()
        out.fragment = nil
        guard let s = out.string else { throw RepositoryInputError("Endereço de repositório inválido.") }
        return s
    }

    /// Chave para comparar endereços equivalentes, como
    /// `github.com/o/r/raw/<ramo>/<arq>` e `raw.githubusercontent.com/o/r/<ramo>/<arq>`.
    public static func canonicalKey(_ s: String) -> String {
        guard var comps = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = comps.host?.lowercased() else { return s.lowercased() }
        var parts = comps.path.split(separator: "/").map(String.init)
        var h = host
        if h == "www.github.com" { h = "github.com" }
        if h == "github.com", parts.count >= 4, parts[2] == "raw" {
            parts.remove(at: 2)
            if parts.count >= 5, parts[2] == "refs", parts[3] == "heads" { parts.removeSubrange(2...3) }
            h = "raw.githubusercontent.com"
        }
        if h == "raw.githubusercontent.com" || h == "github.com" {
            if parts.count >= 2 { parts[0] = parts[0].lowercased(); parts[1] = parts[1].lowercased() }
        }
        comps.scheme = "https"
        comps.host = h
        comps.path = "/" + parts.joined(separator: "/")
        comps.fragment = nil
        return comps.string ?? s
    }

    public static func same(_ a: String, _ b: String) -> Bool { canonicalKey(a) == canonicalKey(b) }

    /// Nome provisório enquanto o índice não foi baixado (ex.: "keiyoushi/extensions").
    public static func displayName(_ s: String) -> String {
        guard let comps = URLComponents(string: s), let host = comps.host?.lowercased() else { return s }
        let parts = comps.path.split(separator: "/")
        let github = ["raw.githubusercontent.com", "github.com", "www.github.com"]
        if github.contains(host), parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        return host
    }
}

/// Plano de sincronização entre a lista do app e os repositórios do servidor.
public enum RepositorySync {
    public struct Plan: Equatable, Sendable {
        /// Repositórios do app que faltam no servidor.
        public var addToServer: [String]
        /// Lista do app depois de incorporar os do servidor (sem duplicatas).
        public var mergedLocal: [String]
    }

    public static func plan(local: [String], server: [ExtensionRepository]) -> Plan {
        var merged: [String] = []
        var seen = Set<String>()
        for url in local where seen.insert(RepositoryURL.canonicalKey(url)).inserted { merged.append(url) }
        let serverKeys = Set(server.map { RepositoryURL.canonicalKey($0.indexURL) })
        let add = merged.filter { !serverKeys.contains(RepositoryURL.canonicalKey($0)) }
        for repo in server where seen.insert(RepositoryURL.canonicalKey(repo.indexURL)).inserted {
            merged.append(repo.indexURL)
        }
        return Plan(addToServer: add, mergedLocal: merged)
    }
}

/// Links "adicionar repositório" publicados por sites de repositórios.
/// Formatos do Mihon (MainActivity.isAddExtensionStoreIntent): `tachiyomi://add-repo?url=…`
/// e `mihon://extension-store?url=…`; mais o equivalente `freeyomi://add-repo?url=…`.
/// O link só preenche a tela de confirmação: nada é adicionado sem o usuário tocar em "Adicionar".
public enum RepositoryDeepLink {
    public static let schemes = ["freeyomi", "tachiyomi", "mihon"]

    public static func parse(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let valid = (scheme == "tachiyomi" && host == "add-repo")
            || (scheme == "mihon" && host == "extension-store")
            || (scheme == "freeyomi" && host == "add-repo")
        guard valid,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let normalized = try? RepositoryURL.normalize(value) else { return nil }
        return normalized
    }
}
