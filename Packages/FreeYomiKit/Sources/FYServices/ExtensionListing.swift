import Foundation
import FYCore
import FYDomain
import FYSources

/// Estado exibido para cada extensão na tela "Extensões".
public enum ExtensionRowState: Equatable, Sendable {
    case available
    case downloading
    case installed
    case updateAvailable(installedVersion: String)
    /// Não pode ser usada neste app (extensão Android ou adaptador ausente).
    case incompatible(String)
    case failed(String)
    /// O repositório não respondeu na última atualização (dados do cache).
    case repositoryUnavailable

    public var label: String {
        switch self {
        case .available: return "Disponível"
        case .downloading: return "Baixando"
        case .installed: return "Instalada"
        case .updateAvailable: return "Atualização disponível"
        case .incompatible: return "Incompatível"
        case .failed: return "Falha na instalação"
        case .repositoryUnavailable: return "Repositório indisponível"
        }
    }

    /// Grupo usado no filtro por estado.
    public var filter: ExtensionStateFilter {
        switch self {
        case .available, .downloading, .repositoryUnavailable: return .available
        case .installed: return .installed
        case .updateAvailable: return .updates
        case .incompatible: return .incompatible
        case .failed: return .failed
        }
    }
}

public enum ExtensionStateFilter: String, CaseIterable, Sendable, Identifiable {
    case all, available, installed, updates, incompatible, failed
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "Todos os estados"
        case .available: return "Disponíveis"
        case .installed: return "Instaladas"
        case .updates: return "Com atualização"
        case .incompatible: return "Incompatíveis"
        case .failed: return "Com falha"
        }
    }
}

/// Onde a extensão é executada.
public enum ExtensionRuntime: Equatable, Sendable {
    /// No iPhone, por um adaptador nativo.
    case device
    /// No servidor de extensões do usuário (Suwayomi-Server).
    case server
    /// Em lugar nenhum: incompatível.
    case none
}

/// Origem do item, sempre visível para o usuário.
public enum ExtensionOrigin: Equatable, Sendable {
    case repository(url: String, name: String, badge: String)
    /// O repositório foi removido, mas a extensão continua instalada.
    case removedRepository(url: String)
    /// Importada de um arquivo.
    case importedFile
    /// Instalada no servidor, de um repositório que não está na lista do app.
    case serverOnly

    public var label: String {
        switch self {
        case .repository(_, let name, _): return name
        case .removedRepository: return "Repositório removido"
        case .importedFile: return "Arquivo importado"
        case .serverOnly: return "Somente no servidor"
        }
    }

    public var repositoryURL: String? {
        switch self {
        case .repository(let url, _, _), .removedRepository(let url): return url
        case .importedFile, .serverOnly: return nil
        }
    }
}

/// Estado de uma extensão no servidor de extensões.
public struct ServerExtensionState: Sendable, Equatable {
    public var installed: Bool
    public var hasUpdate: Bool
    public var versionName: String
    public var name: String
    public var lang: String
    public var iconURL: String

    public init(installed: Bool, hasUpdate: Bool, versionName: String, name: String = "", lang: String = "", iconURL: String = "") {
        self.installed = installed
        self.hasUpdate = hasUpdate
        self.versionName = versionName
        self.name = name
        self.lang = lang
        self.iconURL = iconURL
    }
}

/// Uma linha da tela "Extensões".
public struct ExtensionListing: Identifiable, Sendable {
    public let id: String
    public let packageName: String
    public let name: String
    public let languages: [String]
    public let versionName: String
    public let versionCode: Int64
    public let iconURL: String
    public let contentWarning: ContentWarning
    public let origin: ExtensionOrigin
    public let compatibility: ExtensionCompatibility
    public let runtime: ExtensionRuntime
    public let state: ExtensionRowState
    public let installedVersionName: String?
    /// A extensão do catálogo, quando existe (necessária para instalar).
    public let catalogEntry: CatalogExtension?
    /// Instalada com SHA-256 conferido.
    public let integrityVerified: Bool?

    public var isNSFW: Bool { contentWarning == .nsfw }

    public var languageLabel: String {
        languages.isEmpty ? "all" : (languages.count == 1 ? languages[0] : "all")
    }
}

public enum ExtensionListBuilder {
    /// Junta catálogo (repositórios do usuário), extensões nativas instaladas e,
    /// com servidor conectado, o estado das extensões Android no servidor.
    public static func build(catalogs: [RepositoryCatalog],
                             repositories: [RepositoryRecord],
                             installed: [InstalledExtensionRecord],
                             adapters: AdapterRegistry,
                             server: [String: ServerExtensionState]?,
                             inProgress: Set<String> = [],
                             failures: [String: String] = [:]) -> [ExtensionListing] {
        var rows: [ExtensionListing] = []
        var matchedInstalled = Set<String>()
        var matchedServer = Set<String>()
        let installedByID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for catalog in catalogs {
            guard let snap = catalog.snapshot else { continue }
            let record = repositories.first { RepositoryURL.same($0.url, catalog.indexURL) }
            let repoName = record?.name ?? snap.index.name
            let badge = record?.badgeLabel ?? snap.index.badgeLabel
            let origin = ExtensionOrigin.repository(url: catalog.indexURL, name: repoName, badge: badge)
            let unavailable = catalog.isUnavailable

            for ext in snap.index.extensions {
                let compat = CompatibilityResolver.resolve(ext, adapters: adapters)
                let rowID = "\(catalog.indexURL)|\(ext.packageName)"
                var state: ExtensionRowState
                var runtime: ExtensionRuntime = .none
                var installedVersion: String?
                var verified: Bool?

                switch compat {
                case .compatible:
                    runtime = .device
                    let mine = installedByID[ext.packageName].flatMap { rec -> InstalledExtensionRecord? in
                        guard let url = rec.repositoryURL else { return nil }
                        return RepositoryURL.same(url, catalog.indexURL) ? rec : nil
                    }
                    if let mine { matchedInstalled.insert(mine.id) }
                    installedVersion = mine?.versionName
                    verified = mine?.integrityVerified
                    if inProgress.contains(ext.packageName) {
                        state = .downloading
                    } else if let mine {
                        if let error = mine.lastError {
                            state = .failed(error)
                        } else {
                            state = mine.versionCode < ext.versionCode
                                ? .updateAvailable(installedVersion: mine.versionName) : .installed
                        }
                    } else if let error = failures[ext.packageName] {
                        state = .failed(error)
                    } else if unavailable {
                        state = .repositoryUnavailable
                    } else {
                        state = .available
                    }
                case .unsupportedAdapter(let message):
                    state = .incompatible(message)
                case .requiresAndroid:
                    if let server {
                        runtime = .server
                        let remote = server[ext.packageName]
                        if remote != nil { matchedServer.insert(ext.packageName) }
                        installedVersion = (remote?.installed ?? false) ? remote?.versionName : nil
                        if inProgress.contains(ext.packageName) {
                            state = .downloading
                        } else if let error = failures[ext.packageName] {
                            state = .failed(error)
                        } else if let remote, remote.installed {
                            state = remote.hasUpdate ? .updateAvailable(installedVersion: remote.versionName) : .installed
                        } else if remote == nil {
                            state = .repositoryUnavailable // o servidor ainda não conhece este repositório
                        } else {
                            state = .available
                        }
                    } else {
                        state = .incompatible("Extensão Android (APK/JAR): o iOS não executa esse código. "
                                              + "Para usá-la, conecte um servidor de extensões.")
                    }
                }

                rows.append(ExtensionListing(
                    id: rowID, packageName: ext.packageName, name: ext.name, languages: ext.languages,
                    versionName: ext.versionName, versionCode: ext.versionCode, iconURL: ext.iconURL,
                    contentWarning: ext.contentWarning, origin: origin, compatibility: compat, runtime: runtime,
                    state: state, installedVersionName: installedVersion, catalogEntry: ext, integrityVerified: verified))
            }
        }

        // Instaladas que não aparecem em nenhum catálogo atual.
        for rec in installed where !matchedInstalled.contains(rec.id) {
            let origin: ExtensionOrigin
            if let url = rec.repositoryURL {
                origin = repositories.contains { RepositoryURL.same($0.url, url) }
                    ? .repository(url: url, name: repositories.first { RepositoryURL.same($0.url, url) }?.name
                                  ?? RepositoryURL.displayName(url), badge: "")
                    : .removedRepository(url: url)
            } else {
                origin = .importedFile
            }
            let support = adapters.support(adapter: rec.adapter, version: rec.adapterVersion)
            let manifest = try? NativeExtensionManifest.parse(rec.manifest)
            let state: ExtensionRowState
            if inProgress.contains(rec.id) {
                state = .downloading
            } else if !support.isSupported {
                state = .failed(support.message)
            } else if let error = rec.lastError {
                state = .failed(error)
            } else {
                state = .installed
            }
            var seen = Set<String>()
            let langs = (manifest?.sources.map(\.language) ?? []).filter { seen.insert($0).inserted }
            rows.append(ExtensionListing(
                id: "installed|\(rec.id)", packageName: rec.id, name: rec.name, languages: langs,
                versionName: rec.versionName, versionCode: rec.versionCode, iconURL: "",
                contentWarning: manifest?.contentWarning ?? .unspecified, origin: origin,
                compatibility: support.isSupported ? .compatible(adapter: rec.adapter) : .unsupportedAdapter(support.message),
                runtime: .device, state: state, installedVersionName: rec.versionName, catalogEntry: nil,
                integrityVerified: rec.integrityVerified))
        }

        // Extensões instaladas no servidor vindas de repositórios fora da lista do app.
        if let server {
            for (pkg, remote) in server where remote.installed && !matchedServer.contains(pkg) {
                rows.append(ExtensionListing(
                    id: "server|\(pkg)", packageName: pkg, name: remote.name.isEmpty ? pkg : remote.name,
                    languages: remote.lang.isEmpty ? [] : [remote.lang], versionName: remote.versionName, versionCode: 0,
                    iconURL: remote.iconURL, contentWarning: .unspecified, origin: .serverOnly,
                    compatibility: .requiresAndroid, runtime: .server,
                    state: remote.hasUpdate ? .updateAvailable(installedVersion: remote.versionName) : .installed,
                    installedVersionName: remote.versionName, catalogEntry: nil, integrityVerified: nil))
            }
        }
        return rows
    }
}
