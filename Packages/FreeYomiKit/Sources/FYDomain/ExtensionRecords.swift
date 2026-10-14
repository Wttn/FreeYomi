import Foundation

/// Repositório de extensões cadastrado pelo usuário (persistido no SQLite).
///
/// O app não vem com nenhum: cada registro existe porque o usuário colou o
/// endereço e confirmou. Nada disso é enviado a servidores do FreeYomi.
public struct RepositoryRecord: Sendable, Hashable, Identifiable, Codable {
    /// Endereço informado pelo usuário (já normalizado).
    public var url: String
    /// Chave para detectar endereços equivalentes (duplicatas).
    public var canonicalKey: String
    /// Nome lido do índice, quando disponível.
    public var name: String?
    public var badgeLabel: String?
    public var website: String?
    public var discord: String?
    public var signingKey: String?
    /// Formato do índice (`RepositoryIndexFormat.rawValue`).
    public var format: String?
    public var extensionCount: Int?
    public var position: Int
    /// O usuário permitiu HTTP sem criptografia para este repositório.
    public var allowsInsecureHTTP: Bool
    public var addedAt: Date
    public var lastSyncAt: Date?
    public var lastSyncSucceeded: Bool?
    public var lastSyncError: String?

    public var id: String { url }

    public init(url: String, canonicalKey: String, name: String? = nil, badgeLabel: String? = nil,
                website: String? = nil, discord: String? = nil, signingKey: String? = nil, format: String? = nil,
                extensionCount: Int? = nil, position: Int = 0, allowsInsecureHTTP: Bool = false,
                addedAt: Date = Date(), lastSyncAt: Date? = nil, lastSyncSucceeded: Bool? = nil,
                lastSyncError: String? = nil) {
        self.url = url
        self.canonicalKey = canonicalKey
        self.name = name
        self.badgeLabel = badgeLabel
        self.website = website
        self.discord = discord
        self.signingKey = signingKey
        self.format = format
        self.extensionCount = extensionCount
        self.position = position
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.addedAt = addedAt
        self.lastSyncAt = lastSyncAt
        self.lastSyncSucceeded = lastSyncSucceeded
        self.lastSyncError = lastSyncError
    }
}

/// Extensão nativa instalada (manifesto declarativo + adaptador do app).
public struct InstalledExtensionRecord: Sendable, Hashable, Identifiable, Codable {
    /// Identificador da extensão (ex.: "org.exemplo.fonte").
    public var id: String
    public var name: String
    /// Repositório de origem; `nil` quando importada de um arquivo.
    public var repositoryURL: String?
    public var versionCode: Int64
    public var versionName: String
    public var adapter: String
    public var adapterVersion: Int
    /// Manifesto exatamente como foi baixado e conferido.
    public var manifest: Data
    public var sha256: String
    /// SHA-256 conferido com o valor publicado pelo repositório.
    public var integrityVerified: Bool
    /// Preferência: instalar atualizações deste item sem perguntar.
    public var autoUpdate: Bool
    public var installedAt: Date
    public var updatedAt: Date
    /// Falha ao ativar as fontes na última inicialização, se houver.
    public var lastError: String?

    public init(id: String, name: String, repositoryURL: String?, versionCode: Int64, versionName: String,
                adapter: String, adapterVersion: Int, manifest: Data, sha256: String, integrityVerified: Bool,
                autoUpdate: Bool = false, installedAt: Date = Date(), updatedAt: Date = Date(), lastError: String? = nil) {
        self.id = id
        self.name = name
        self.repositoryURL = repositoryURL
        self.versionCode = versionCode
        self.versionName = versionName
        self.adapter = adapter
        self.adapterVersion = adapterVersion
        self.manifest = manifest
        self.sha256 = sha256
        self.integrityVerified = integrityVerified
        self.autoUpdate = autoUpdate
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}
