import Foundation
import Observation
import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Composição do aplicativo: banco local, fontes, serviços e preferências.
///
/// Tudo é local. Nenhum dado da biblioteca sai do aparelho.
@MainActor
@Observable
final class AppModel {
    let store: DataStore
    let registry: SourceRegistry
    let service: LibraryService
    let catalog: ExtensionCatalogClient
    /// Títulos importados (CBZ/ZIP/EPUB/pastas), dentro do contêiner do app.
    let localStore: LocalLibraryStore
    let importer: LocalImporter

    /// Importação em andamento e resultado da última.
    var isImporting = false
    var importStatus: String?

    /// Preferências; cada alteração é salva imediatamente no SQLite.
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            do { try store.settings.save(settings) } catch { report(error) }
            if settings.mangaDexEnabled != oldValue.mangaDexEnabled
                || settings.mangaDexLanguage != oldValue.mangaDexLanguage
                || settings.mangaDexDataSaver != oldValue.mangaDexDataSaver
                || settings.showNSFWExtensions != oldValue.showNSFWExtensions {
                configureMangaDex()
            }
        }
    }

    // MARK: Servidor de extensões (Suwayomi-Server)

    enum ServerState: Equatable {
        case notConfigured
        case connecting
        case connected(name: String, version: String, sources: Int)
        case failed(String)
    }

    var serverState: ServerState = .notConfigured
    private(set) var serverClient: SuwayomiClient?

    // MARK: Repositórios de extensões

    /// Metadados de cada repositório da lista (último índice baixado ou erro).
    private(set) var repositoryCatalogs: [RepositoryCatalog] = []
    /// Repositórios como o servidor os guarda (com servidor conectado).
    private(set) var serverRepositories: [ExtensionRepository] = []
    /// Pacote da extensão → `indexUrl` do repositório de origem, no servidor.
    private(set) var serverExtensionStores: [String: String] = [:]
    private(set) var isRefreshingRepositories = false
    /// Aviso da última sincronização com o servidor, se algo falhou.
    private(set) var repositorySyncNote: String?
    /// Endereço recebido por link (`tachiyomi://add-repo?url=…`), aguardando confirmação.
    var pendingRepositoryURL: String?

    /// Incrementado após qualquer mutação, para que as telas recarreguem.
    private(set) var dataVersion = 0

    /// Mensagem de erro exibida em alerta.
    var alertMessage: String?

    /// Aviso de inicialização (ex.: banco recuperado de corrupção).
    var startupNotice: String?

    /// Resultado da última verificação de atualizações.
    var lastRefresh: RefreshReport?
    var isRefreshing = false

    private var didBootstrap = false

    init(store: DataStore, registry: SourceRegistry, catalogCache: URL, localStore: LocalLibraryStore) {
        self.store = store
        self.registry = registry
        self.localStore = localStore
        self.importer = LocalImporter(store: localStore)
        ImagePipeline.shared.localRoot = localStore.root
        self.service = LibraryService(store: store, registry: registry)
        self.catalog = ExtensionCatalogClient(http: URLSessionHTTPClient(), cacheDirectory: catalogCache)
        self.settings = store.settings.load()
    }

    /// Abre o banco no diretório Application Support. Em testes de interface
    /// (`-ui-testing`) usa um banco em memória.
    static func makeForLaunch() -> AppModel {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                   create: true)) ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let localRoot = uiTesting
            ? fm.temporaryDirectory.appendingPathComponent("ui-tests-local-\(UUID().uuidString)", isDirectory: true)
            : support.appendingPathComponent("FreeYomi/LocalFiles", isDirectory: true)
        let localStore = LocalLibraryStore(root: localRoot)
        let registry = SourceRegistry.makeDefault(localStore: localStore)

        if uiTesting, let mem = try? DataStore.inMemory() {
            return AppModel(store: mem, registry: registry, catalogCache: caches.appendingPathComponent("ui-tests"),
                            localStore: localStore)
        }

        let dbURL = support.appendingPathComponent("FreeYomi", isDirectory: true)
            .appendingPathComponent("library.sqlite")
        do {
            let store = try DataStore.open(fileURL: dbURL)
            let model = AppModel(store: store, registry: registry,
                                 catalogCache: caches.appendingPathComponent("catalog", isDirectory: true),
                                 localStore: localStore)
            if store.recoveredFromCorruption {
                model.startupNotice = "O banco de dados estava danificado e foi recriado. "
                    + "O arquivo original foi preservado para recuperação manual."
            }
            return model
        } catch {
            // Último recurso: banco temporário para o app abrir mesmo assim.
            let mem = try! DataStore.inMemory()
            let model = AppModel(store: mem, registry: registry, catalogCache: caches, localStore: localStore)
            model.startupNotice = "Não foi possível abrir a biblioteca local (\(error.localizedDescription)). "
                + "Os dados desta sessão não serão salvos."
            return model
        }
    }

    /// Prepara fontes e dados de demonstração. Não depende de internet.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try service.syncSourceTable()
            try await service.seedDemoDataIfNeeded()
            settings = store.settings.load()
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-sample"),
               let sample = try? SampleArchive.make() {
                await importFiles([sample], securityScoped: false)
            }
        } catch {
            report(error)
        }
        configureMangaDex()
        if !ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            Task { await connectServer() }
        }
        if let notice = startupNotice { alertMessage = notice }
        dataVersion += 1
        let disk = ImagePipeline.shared.disk
        Task.detached(priority: .background) { disk.trim() }
    }

    // MARK: - Mutações

    /// Executa uma alteração no banco, informa erros e notifica as telas.
    func mutate(_ body: () throws -> Void) {
        do {
            try body()
            dataVersion += 1
        } catch {
            report(error)
        }
    }

    func touch() { dataVersion += 1 }

    func report(_ error: Error) {
        if let fy = error as? FYError, fy == .cancelled { return }
        alertMessage = error.localizedDescription
    }

    func refreshLibrary() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = await service.refreshLibrary(skipCompleted: settings.skipUpdatingCompleted)
        dataVersion += 1
    }

    func restoreDemoData() async {
        var s = settings
        s.demoDataSeeded = false
        settings = s
        do {
            try await service.seedDemoDataIfNeeded()
            settings = store.settings.load()
        } catch { report(error) }
        dataVersion += 1
    }

    // MARK: - Fontes online

    /// Registra (ou remove) a fonte nativa do MangaDex conforme as preferências.
    func configureMangaDex() {
        if settings.mangaDexEnabled {
            registry.register(MangaDexSource(language: settings.mangaDexLanguage,
                                             includeAdult: settings.showNSFWExtensions,
                                             dataSaver: settings.mangaDexDataSaver))
        } else {
            registry.unregister("mangadex")
        }
        try? service.syncSourceTable()
        dataVersion += 1
    }

    private func currentServerConfig() -> SuwayomiConfig? {
        guard let raw = settings.extensionServerURL, let url = SuwayomiConfig.normalize(raw) else { return nil }
        return SuwayomiConfig(baseURL: url, username: settings.extensionServerUsername,
                              password: KeychainStore.get(account: KeychainStore.extensionServerPassword),
                              allowInsecureHTTP: settings.extensionServerAllowHTTP)
    }

    /// Conecta ao servidor configurado e registra as fontes das extensões instaladas nele.
    func connectServer() async {
        guard let config = currentServerConfig() else {
            serverState = .notConfigured
            serverClient = nil
            registry.replaceSources(withPrefix: SuwayomiSource.prefix, with: [])
            ImagePipeline.shared.serverConfig = nil
            await syncRepositoriesWithServer()
            dataVersion += 1
            return
        }
        serverState = .connecting
        let client = SuwayomiClient(config: config)
        ImagePipeline.shared.serverConfig = config
        do {
            let about = try await client.about()
            let infos = try await client.sources()
            let visible = infos.filter { settings.showNSFWExtensions || !$0.isNsfw }
            registry.replaceSources(withPrefix: SuwayomiSource.prefix,
                                    with: visible.map { SuwayomiSource(info: $0, client: client) })
            try? service.syncSourceTable()
            serverClient = client
            serverState = .connected(name: about.name, version: about.version, sources: visible.count)
            await syncRepositoriesWithServer()
        } catch {
            serverClient = nil
            serverState = .failed(error.localizedDescription)
            await syncRepositoriesWithServer()
        }
        dataVersion += 1
    }

    /// Salva o endereço e as credenciais (senha no Keychain) e reconecta.
    func saveServer(address: String, username: String, password: String, allowHTTP: Bool) async {
        guard let url = SuwayomiConfig.normalize(address) else {
            serverState = .failed("Endereço inválido. Exemplo: http://192.168.0.10:4567")
            return
        }
        var s = settings
        s.extensionServerURL = url.absoluteString
        s.extensionServerUsername = username.isEmpty ? nil : username
        s.extensionServerAllowHTTP = allowHTTP
        settings = s
        KeychainStore.set(password, account: KeychainStore.extensionServerPassword)
        await connectServer()
    }

    func disconnectServer() async {
        var s = settings
        s.extensionServerURL = nil
        s.extensionServerUsername = nil
        settings = s
        KeychainStore.set(nil, account: KeychainStore.extensionServerPassword)
        await connectServer()
    }

    // MARK: - Arquivos locais

    /// Importa arquivos/pastas escolhidos pelo usuário. URLs do seletor de
    /// arquivos são "security-scoped": o acesso é liberado só durante a cópia.
    func importFiles(_ urls: [URL], securityScoped: Bool = true) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        importStatus = urls.count == 1 ? "Importando \(urls[0].lastPathComponent)…" : "Importando \(urls.count) itens…"
        let granted = securityScoped ? urls.map { $0.startAccessingSecurityScopedResource() } : []
        let categories = settings.defaultCategoryId.map { [$0] } ?? []
        let report = await service.importLocal(urls: urls, importer: importer, categoryIds: categories)
        for (url, ok) in zip(urls, granted) where ok { url.stopAccessingSecurityScopedResource() }
        isImporting = false
        importStatus = nil
        dataVersion += 1

        var lines: [String] = []
        if !report.imported.isEmpty {
            lines.append("Importado(s): " + report.imported.map(\.title).joined(separator: ", ") + ".")
        }
        if !report.duplicates.isEmpty {
            lines.append("Já estavam na biblioteca: " + report.duplicates.joined(separator: ", ") + ".")
        }
        for f in report.failures { lines.append("Falha em \(f.name): \(f.reason)") }
        if report.skippedFiles > 0 { lines.append("\(report.skippedFiles) arquivo(s) que não são imagens foram ignorados.") }
        if !report.failures.isEmpty || !report.duplicates.isEmpty || report.skippedFiles > 0 {
            alertMessage = lines.joined(separator: "\n")
        } else if !report.imported.isEmpty {
            Haptics.success()
        }
    }

    /// Arquivo aberto a partir de outro app ("Abrir com FreeYomi").
    func handleOpenURL(_ url: URL) {
        if RepositoryDeepLink.schemes.contains(url.scheme?.lowercased() ?? "") {
            if let repo = RepositoryDeepLink.parse(url) {
                pendingRepositoryURL = repo
            } else {
                alertMessage = "Link de repositório inválido. O endereço precisa usar HTTPS."
            }
            return
        }
        Task {
            await importFiles([url], securityScoped: true)
            // Cópias recebidas em Documents/Inbox não são mais necessárias.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Repositórios de extensões

    /// Informações para exibir: o servidor (quando conectado) e, na falta, o índice baixado.
    func repositoryInfo(_ url: String) -> ExtensionRepository {
        let fromServer = serverRepositories.first { RepositoryURL.same($0.indexURL, url) }
        let fromCatalog = repositoryCatalogs.first { RepositoryURL.same($0.indexURL, url) }?.snapshot
            .map { ExtensionRepository(indexURL: url, index: $0.index) }
        var repo = fromServer ?? fromCatalog ?? ExtensionRepository(indexURL: url, name: RepositoryURL.displayName(url))
        repo.indexURL = url
        if repo.website == nil { repo.website = fromCatalog?.website }
        if repo.discord == nil { repo.discord = fromCatalog?.discord }
        if repo.signingKey == nil { repo.signingKey = fromCatalog?.signingKey }
        if repo.extensionCount == nil { repo.extensionCount = fromCatalog?.extensionCount }
        return repo
    }

    func repositoryError(_ url: String) -> String? {
        repositoryCatalogs.first { RepositoryURL.same($0.indexURL, url) }?.error
    }

    func isOnServer(_ url: String) -> Bool {
        serverRepositories.contains { RepositoryURL.same($0.indexURL, url) }
    }

    func isRepositoryAdded(_ url: String) -> Bool {
        settings.extensionRepositories.contains { RepositoryURL.same($0, url) }
    }

    /// Selo do repositório de origem de uma extensão instalada no servidor (ex.: "KEI").
    func repositoryBadge(forPackage pkg: String) -> String? {
        guard let store = serverExtensionStores[pkg] else { return nil }
        let label = repositoryInfo(store).badgeLabel
        return label.isEmpty ? nil : label
    }

    /// Lê os índices salvos (sem rede).
    func loadCachedRepositories() {
        repositoryCatalogs = catalog.cachedAll(settings.extensionRepositories)
    }

    /// Baixa de novo os índices de todos os repositórios e sincroniza com o servidor.
    func refreshRepositories() async {
        guard !isRefreshingRepositories else { return }
        isRefreshingRepositories = true
        defer { isRefreshingRepositories = false }
        repositoryCatalogs = await catalog.refreshAll(settings.extensionRepositories)
        await syncRepositoriesWithServer()
    }

    /// Baixa e valida o índice antes de adicionar (só metadados; nada é executado).
    func previewRepository(_ raw: String) async throws -> (url: String, snapshot: CatalogSnapshot) {
        let url = try RepositoryURL.normalize(raw)
        if isRepositoryAdded(url) { throw RepositoryInputError.alreadyAdded }
        let snapshot = try await catalog.refresh(from: url)
        return (url, snapshot)
    }

    /// Adiciona o repositório ao app e, com servidor conectado, ao servidor.
    /// Devolve um aviso quando o servidor não aceitou.
    @discardableResult
    func addRepository(url: String, snapshot: CatalogSnapshot?) async -> String? {
        guard !isRepositoryAdded(url) else { return nil }
        var s = settings
        s.extensionRepositories.append(url)
        settings = s
        repositoryCatalogs.append(RepositoryCatalog(indexURL: url, snapshot: snapshot, error: nil))
        var note: String?
        if let client = serverClient {
            do {
                try await client.addExtensionStore(indexURL: url)
                await syncRepositoriesWithServer()
            } catch {
                note = "Adicionado no app, mas o servidor não aceitou: \(error.localizedDescription)"
            }
        }
        dataVersion += 1
        return note
    }

    /// Remove o repositório do app e do servidor.
    func removeRepository(_ url: String) async {
        if let client = serverClient,
           let onServer = serverRepositories.first(where: { RepositoryURL.same($0.indexURL, url) }) {
            do {
                try await client.removeExtensionStore(indexURL: onServer.indexURL)
            } catch {
                report(error)
                return // sem isso, a próxima sincronização traria o repositório de volta
            }
        }
        var s = settings
        s.extensionRepositories.removeAll { RepositoryURL.same($0, url) }
        settings = s
        repositoryCatalogs.removeAll { RepositoryURL.same($0.indexURL, url) }
        serverRepositories.removeAll { RepositoryURL.same($0.indexURL, url) }
        catalog.removeCache(for: url)
        if serverClient != nil { await syncRepositoriesWithServer() }
        dataVersion += 1
    }

    func moveRepositories(from offsets: IndexSet, to destination: Int) {
        var s = settings
        s.extensionRepositories.move(fromOffsets: offsets, toOffset: destination)
        settings = s
    }

    /// Une a lista do app com a do servidor: o que falta no servidor é adicionado
    /// lá; o que só existe no servidor entra na lista do app.
    func syncRepositoriesWithServer() async {
        guard let client = serverClient else {
            serverRepositories = []
            serverExtensionStores = [:]
            repositorySyncNote = nil
            return
        }
        do {
            var server = try await client.extensionStores()
            let plan = RepositorySync.plan(local: settings.extensionRepositories, server: server)
            var failures: [String] = []
            for url in plan.addToServer {
                do {
                    try await client.addExtensionStore(indexURL: url)
                } catch {
                    failures.append("\(RepositoryURL.displayName(url)): \(error.localizedDescription)")
                }
            }
            if !plan.addToServer.isEmpty {
                server = (try? await client.extensionStores()) ?? server
            }
            if plan.mergedLocal != settings.extensionRepositories {
                var s = settings
                s.extensionRepositories = plan.mergedLocal
                settings = s
            }
            serverRepositories = server
            serverExtensionStores = (try? await client.extensionStoreIndex()) ?? [:]
            repositorySyncNote = failures.isEmpty ? nil
                : "O servidor não aceitou: " + failures.joined(separator: "; ")
        } catch {
            serverRepositories = []
            serverExtensionStores = [:]
            repositorySyncNote = "Não foi possível ler os repositórios do servidor (\(error.localizedDescription)). "
                + "Atualize o Suwayomi-Server para uma versão recente."
        }
    }

    func deleteLocalFiles(of manga: Manga) {
        mutate { try service.deleteLocalManga(manga, store: localStore) }
    }

    func removeDemoData() {
        mutate { try store.library.deleteDemoData() }
    }
}

extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
