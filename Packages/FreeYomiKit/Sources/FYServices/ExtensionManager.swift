import Foundation
import FYCore
import FYDomain
import FYData
import FYSources

/// Índice conferido em "Validar", aguardando o usuário tocar em "Adicionar".
public struct RepositoryPreview: Sendable {
    public let url: String
    public let snapshot: CatalogSnapshot
    /// O endereço usa HTTP e o usuário habilitou essa opção.
    public let allowsInsecureHTTP: Bool

    public var repository: ExtensionRepository { ExtensionRepository(indexURL: url, index: snapshot.index) }
}

/// O que aconteceu ao remover um repositório (para informar o usuário).
public struct RepositoryRemovalSummary: Sendable {
    public let removed: RepositoryRecord
    /// Extensões instaladas a partir dele, que continuam instaladas.
    public let keptInstalledExtensions: [String]
}

/// Resultado da migração das preferências 0.3.x para o banco.
public struct RepositoryMigrationResult: Sendable, Equatable {
    public var imported: [String] = []
    /// O repositório que vinha pré-configurado foi retirado da lista.
    public var removedPreconfigured = false
}

/// Casos de uso de repositórios e extensões: cadastro com validação, cache,
/// sincronização, instalação de extensões nativas e ativação das fontes.
///
/// Tudo fica no aparelho. Nenhuma lista de repositórios é enviada a terceiros.
public final class ExtensionManager: @unchecked Sendable {
    public let store: DataStore
    public let catalog: ExtensionCatalogClient
    public let installer: NativeExtensionInstaller
    public let registry: SourceRegistry
    public var adapters: AdapterRegistry { installer.adapters }
    /// Extensões Android (.jar) executadas pela JVM embutida; `nil` sem o runtime.
    public let jvm: JVMExtensionLoader?
    public var jvmAvailable: Bool { jvm?.installer.bridge.isAvailable ?? false }

    /// Endereço que vinha pré-configurado nas versões 0.1–0.3.1. Serve SÓ para
    /// reconhecer esse padrão antigo e retirá-lo na migração; nunca é oferecido.
    static let legacyPreconfiguredRepository = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"

    public init(store: DataStore, catalog: ExtensionCatalogClient, registry: SourceRegistry,
                adapters: AdapterRegistry = .builtIn, jvm: JVMExtensionInstaller? = nil) {
        self.store = store
        self.catalog = catalog
        self.registry = registry
        self.installer = NativeExtensionInstaller(catalog: catalog, adapters: adapters)
        self.jvm = jvm.map(JVMExtensionLoader.init(installer:))
    }

    // MARK: - Repositórios

    public func repositories() -> [RepositoryRecord] {
        (try? store.extensionRepos.all()) ?? []
    }

    public func repository(_ url: String) -> RepositoryRecord? {
        repositories().first { RepositoryURL.same($0.url, url) }
    }

    public func isAdded(_ url: String) -> Bool {
        (try? store.extensionRepos.record(canonicalKey: RepositoryURL.canonicalKey(url))) != nil
    }

    /// "Validar": normaliza o endereço, recusa duplicatas e baixa o índice
    /// (sem gravar nada). Só metadados são lidos; nada é executado.
    public func preview(_ raw: String, allowHTTP: Bool = false) async throws -> RepositoryPreview {
        let url = try RepositoryURL.normalize(raw, allowHTTP: allowHTTP)
        if isAdded(url) { throw RepositoryInputError.alreadyAdded }
        let insecure = RepositoryURL.isInsecure(url)
        let snapshot = try await catalog.fetch(from: url, allowHTTP: insecure)
        return RepositoryPreview(url: url, snapshot: snapshot, allowsInsecureHTTP: insecure)
    }

    /// "Adicionar": grava o repositório já validado e o índice em cache.
    @discardableResult
    public func add(_ preview: RepositoryPreview) throws -> RepositoryRecord {
        if isAdded(preview.url) { throw RepositoryInputError.alreadyAdded }
        let index = preview.snapshot.index
        let record = try store.extensionRepos.insert(RepositoryRecord(
            url: preview.url, canonicalKey: RepositoryURL.canonicalKey(preview.url), name: index.name,
            badgeLabel: index.badgeLabel.nilIfEmpty, website: index.website.nilIfEmpty, discord: index.discord?.nilIfEmpty,
            signingKey: index.signingKey.nilIfEmpty, format: index.format.rawValue, extensionCount: index.extensions.count,
            allowsInsecureHTTP: preview.allowsInsecureHTTP, addedAt: Date(), lastSyncAt: preview.snapshot.fetchedAt,
            lastSyncSucceeded: true, lastSyncError: nil))
        try? catalog.save(preview.snapshot, for: preview.url)
        return record
    }

    /// Cadastra um endereço que o usuário já usava (migração da 0.3.x) ou que
    /// ele adicionou no próprio servidor de extensões. Só HTTPS. Os metadados
    /// chegam na próxima atualização.
    @discardableResult
    public func addWithoutPreview(_ raw: String) throws -> RepositoryRecord? {
        let url = try RepositoryURL.normalize(raw)
        guard !isAdded(url) else { return nil }
        return try store.extensionRepos.insert(RepositoryRecord(url: url, canonicalKey: RepositoryURL.canonicalKey(url),
                                                                name: RepositoryURL.displayName(url)))
    }

    /// Índices salvos (sem rede), na ordem da lista.
    public func cachedCatalogs() -> [RepositoryCatalog] {
        catalog.cachedAll(repositories().map(\.url))
    }

    /// Atualiza um repositório e registra o resultado.
    public func refresh(_ url: String) async -> RepositoryCatalog {
        let allowHTTP = repository(url)?.allowsInsecureHTTP ?? false
        do {
            let snap = try await catalog.refresh(from: url, allowHTTP: allowHTTP)
            recordSync(snap, url: url)
            return RepositoryCatalog(indexURL: url, snapshot: snap, error: snap.networkError)
        } catch {
            try? store.extensionRepos.updateSync(url: url, at: Date(), succeeded: false, error: error.localizedDescription)
            return RepositoryCatalog(indexURL: url, snapshot: nil, error: error.localizedDescription)
        }
    }

    /// Atualiza todos, em paralelo; a falha de um não afeta os outros.
    public func refreshAll() async -> [RepositoryCatalog] {
        let records = repositories()
        let insecure = Set(records.filter(\.allowsInsecureHTTP).map(\.url))
        let results = await catalog.refreshAll(records.map(\.url), allowHTTP: insecure)
        for r in results {
            if let snap = r.snapshot {
                recordSync(snap, url: r.indexURL)
            } else {
                try? store.extensionRepos.updateSync(url: r.indexURL, at: Date(), succeeded: false, error: r.error)
            }
        }
        return results
    }

    private func recordSync(_ snap: CatalogSnapshot, url: String) {
        if snap.isFromCache {
            try? store.extensionRepos.updateSync(url: url, at: Date(), succeeded: false, error: snap.networkError)
        } else {
            let i = snap.index
            try? store.extensionRepos.updateSync(url: url, at: snap.fetchedAt, succeeded: true, error: nil, name: i.name,
                                                 badgeLabel: i.badgeLabel.nilIfEmpty, website: i.website.nilIfEmpty,
                                                 discord: i.discord?.nilIfEmpty, signingKey: i.signingKey.nilIfEmpty,
                                                 format: i.format.rawValue, extensionCount: i.extensions.count)
        }
    }

    /// Remove o repositório e o cache dele. Biblioteca, capítulos baixados e
    /// extensões já instaladas são preservados (as extensões passam a
    /// aparecer como "origem removida" e deixam de receber atualizações).
    @discardableResult
    public func remove(_ url: String) throws -> RepositoryRemovalSummary {
        guard let record = repository(url) else { throw FYError.notFound("repositório") }
        let kept = installedExtensions()
            .filter { $0.repositoryURL.map { RepositoryURL.same($0, record.url) } ?? false }
            .map(\.name)
        try store.extensionRepos.delete(url: record.url)
        catalog.removeCache(for: record.url)
        return RepositoryRemovalSummary(removed: record, keptInstalledExtensions: kept)
    }

    public func reorder(_ urls: [String]) throws {
        try store.extensionRepos.reorder(urls)
    }

    // MARK: - Migração da 0.3.x

    /// Copia a lista antiga (preferências JSON) para o banco, uma única vez.
    /// Se a lista era exatamente o repositório que vinha pré-configurado, ele
    /// é retirado: o app não deve trazer repositórios que o usuário não escolheu.
    public func migrateLegacySettings(_ settings: inout AppSettings) -> RepositoryMigrationResult {
        guard !settings.repositoriesMigrated else { return RepositoryMigrationResult() }
        var result = RepositoryMigrationResult()
        var list = settings.extensionRepositories
        if list.count == 1, RepositoryURL.same(list[0], Self.legacyPreconfiguredRepository) {
            list = []
            result.removedPreconfigured = true
        }
        for url in list {
            if let added = try? addWithoutPreview(url) { result.imported.append(added.url) }
        }
        settings.extensionRepositories = []
        settings.catalogURL = ""
        settings.repositoriesMigrated = true
        return result
    }

    // MARK: - Extensões nativas

    public func installedExtensions() -> [InstalledExtensionRecord] {
        (try? store.installedExtensions.all()) ?? []
    }

    /// Instala (ou atualiza) uma extensão nativa anunciada por um repositório.
    /// Só grava depois de baixar, conferir e criar as fontes com sucesso.
    @discardableResult
    public func install(_ ext: CatalogExtension, from repositoryURL: String) async throws -> InstalledExtensionRecord {
        let repo = repository(repositoryURL)
        if ext.native == nil {
            return try await installJVM(ext, repositoryURL: repo?.url ?? repositoryURL,
                                        allowHTTP: repo?.allowsInsecureHTTP ?? false)
        }
        let package = try await installer.download(ext, allowHTTP: repo?.allowsInsecureHTTP ?? false)
        return try commit(package, repositoryURL: repo?.url ?? repositoryURL)
    }

    /// Instala um manifesto escolhido pelo usuário em "Importar extensão".
    @discardableResult
    public func installManifestFile(_ data: Data) throws -> InstalledExtensionRecord {
        try commit(try installer.verify(data, announcedBy: nil), repositoryURL: nil)
    }

    private func commit(_ package: NativeExtensionPackage, repositoryURL: String?) throws -> InstalledExtensionRecord {
        let m = package.manifest
        // Prova que o adaptador aceita a configuração antes de marcar como instalada.
        let sources = try installer.makeSources(m, context: AdapterContext())
        guard !sources.isEmpty else { throw FYError.invalidData("a extensão não declarou nenhuma fonte") }
        let existing = try store.installedExtensions.record(id: m.id)
        if let existing, existing.versionCode > m.versionCode {
            throw FYError.unsupported("a versão instalada (\(existing.versionName)) é mais nova que a oferecida (\(m.versionName))")
        }
        let now = Date()
        let record = InstalledExtensionRecord(
            id: m.id, name: m.name, repositoryURL: repositoryURL, versionCode: m.versionCode, versionName: m.versionName,
            adapter: m.adapter, adapterVersion: m.adapterVersion, manifest: package.data, sha256: package.sha256,
            integrityVerified: package.integrityVerified, autoUpdate: existing?.autoUpdate ?? false,
            installedAt: existing?.installedAt ?? now, updatedAt: now, lastError: nil)
        try store.installedExtensions.upsert(record)
        return record
    }

    /// Extensão Android: baixa o .jar, carrega na JVM (que lista as fontes) e
    /// só então grava. Uma versão mais antiga é substituída.
    private func installJVM(_ ext: CatalogExtension, repositoryURL: String, allowHTTP: Bool) async throws -> InstalledExtensionRecord {
        guard let jvm, jvmAvailable else {
            throw FYError.unsupported("\(ext.name) é uma extensão Android e esta compilação do app não inclui o runtime de extensões")
        }
        let existing = try store.installedExtensions.record(id: ext.packageName)
        if let existing, existing.versionCode > ext.versionCode {
            throw FYError.unsupported("a versão instalada (\(existing.versionName)) é mais nova que a oferecida (\(ext.versionName))")
        }
        let manifest = try await jvm.installer.install(ext, allowHTTP: allowHTTP)
        await jvm.markLoaded(manifest)
        let data = try manifest.encoded()
        let now = Date()
        let record = InstalledExtensionRecord(
            id: manifest.packageName, name: manifest.name, repositoryURL: repositoryURL, versionCode: manifest.versionCode,
            versionName: manifest.versionName, adapter: JVMExtensionSupport.adapter,
            adapterVersion: JVMExtensionSupport.adapterVersion, manifest: data, sha256: SHA256.hex(data),
            // O índice do Tachiyomi não publica o hash do .jar: a origem é o repositório que o usuário escolheu.
            integrityVerified: false, autoUpdate: existing?.autoUpdate ?? false,
            installedAt: existing?.installedAt ?? now, updatedAt: now, lastError: nil)
        try store.installedExtensions.upsert(record)
        if let existing, existing.adapter == JVMExtensionSupport.adapter,
           let old = try? JVMExtensionManifest.decode(existing.manifest) {
            if old.jarFile != manifest.jarFile { jvm.installer.removeJar(old) }
            for source in old.sources { registry.unregister(JVMExtensionSupport.sourceID(source.id)) }
        }
        for source in jvmSources(manifest, loader: jvm) { registry.register(source) }
        return record
    }

    private func jvmSources(_ manifest: JVMExtensionManifest, loader: JVMExtensionLoader) -> [any MangaSource] {
        manifest.sources.map { source in
            JVMExtensionSource(source: source, extensionName: manifest.name, bridge: loader.installer.bridge,
                               prepare: { try await loader.ensureLoaded(manifest) })
        }
    }

    /// Desinstala a extensão. Os títulos dela continuam na biblioteca (com
    /// capítulos lidos e baixados); só não abrem até reinstalar.
    public func uninstall(_ id: String) throws {
        let record = try store.installedExtensions.record(id: id)
        try store.installedExtensions.delete(id: id)
        if let record, record.adapter == JVMExtensionSupport.adapter,
           let manifest = try? JVMExtensionManifest.decode(record.manifest) {
            jvm?.installer.removeJar(manifest)
            for source in manifest.sources { registry.unregister(JVMExtensionSupport.sourceID(source.id)) }
            return
        }
        let prefix = "\(NativeExtensionManifest.sourcePrefix)\(id)/"
        registry.replaceSources(withPrefix: prefix, with: [])
    }

    public func setAutoUpdate(_ id: String, _ value: Bool) throws {
        try store.installedExtensions.setAutoUpdate(id: id, value)
    }

    /// Registra as fontes de todas as extensões instaladas. Cada extensão é
    /// ativada isoladamente: a falha de uma não impede as outras.
    /// Devolve as falhas por extensão.
    @discardableResult
    public func activateInstalledSources(context: AdapterContext) -> [String: String] {
        var sources: [any MangaSource] = []
        var jvmSources: [any MangaSource] = []
        var failures: [String: String] = [:]
        for record in installedExtensions() {
            do {
                guard SHA256.hex(record.manifest) == record.sha256 else {
                    throw FYError.invalidData("o manifesto salvo foi alterado; reinstale a extensão")
                }
                if record.adapter == JVMExtensionSupport.adapter {
                    guard let jvm, jvmAvailable else {
                        throw FYError.unsupported("extensão Android: esta compilação do app não inclui o runtime de extensões")
                    }
                    // Só registra as fontes; a JVM inicia quando alguma delas for usada.
                    let manifest = try JVMExtensionManifest.decode(record.manifest)
                    jvmSources += self.jvmSources(manifest, loader: jvm)
                    if record.lastError != nil { try? store.installedExtensions.setError(id: record.id, nil) }
                    continue
                }
                let manifest = try NativeExtensionManifest.parse(record.manifest)
                sources += try installer.makeSources(manifest, context: context)
                if record.lastError != nil { try? store.installedExtensions.setError(id: record.id, nil) }
            } catch {
                failures[record.id] = error.localizedDescription
                try? store.installedExtensions.setError(id: record.id, error.localizedDescription)
            }
        }
        registry.replaceSources(withPrefix: NativeExtensionManifest.sourcePrefix, with: sources)
        registry.replaceSources(withPrefix: JVMExtensionSupport.sourcePrefix, with: jvmSources)
        return failures
    }

    /// Instala as atualizações das extensões marcadas com "atualizar automaticamente".
    /// Devolve os nomes atualizados e as falhas (sem interromper as demais).
    public func applyAutoUpdates(_ catalogs: [RepositoryCatalog]) async -> (updated: [String], failed: [String: String]) {
        var updated: [String] = []
        var failed: [String: String] = [:]
        for record in installedExtensions() where record.autoUpdate {
            guard let repoURL = record.repositoryURL,
                  let catalog = catalogs.first(where: { RepositoryURL.same($0.indexURL, repoURL) }),
                  let ext = catalog.snapshot?.index.extensions.first(where: { $0.packageName == record.id }),
                  ext.versionCode > record.versionCode else { continue }
            do {
                try await install(ext, from: repoURL)
                updated.append(record.name)
            } catch {
                failed[record.id] = error.localizedDescription
            }
        }
        return (updated, failed)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
