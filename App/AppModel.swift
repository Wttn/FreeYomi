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
    /// Repositórios e extensões adicionados pelo usuário (nenhum vem de fábrica).
    let extensions: ExtensionManager
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
            if settings.sourceDataSaver != oldValue.sourceDataSaver
                || settings.showNSFWExtensions != oldValue.showNSFWExtensions {
                activateNativeSources()
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

    /// Repositórios cadastrados (banco local), na ordem exibida.
    private(set) var repositories: [RepositoryRecord] = []
    /// Extensões nativas instaladas.
    private(set) var installedExtensions: [InstalledExtensionRecord] = []
    /// Pacotes sendo baixados/instalados agora.
    private(set) var extensionTasks: Set<String> = []
    /// Última falha de instalação por pacote.
    private(set) var extensionFailures: [String: String] = [:]
    /// Extensões conhecidas pelo servidor (com servidor conectado).
    private(set) var serverExtensions: [String: SuwayomiExtension] = [:]
    private(set) var serverExtensionsError: String?
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
        // O catálogo valida o destino por conta própria (HTTPS; HTTP só com opção explícita).
        let catalog = ExtensionCatalogClient(http: URLSessionHTTPClient(policy: .httpsOrHTTP), cacheDirectory: catalogCache)
        self.extensions = ExtensionManager(store: store, catalog: catalog, registry: registry)
        self.settings = store.settings.load()
    }

    /// Abre o banco no diretório Application Support. Em testes de interface
    /// (`-ui-testing`) usa um banco em memória.
    static func makeForLaunch() -> AppModel {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                   create: true)) ?? fm.temporaryDirectory
        // Índices dos repositórios ficam em Application Support (a pasta Caches
        // pode ser apagada pelo iOS, e a lista precisa continuar visível offline).
        let repoCache = support.appendingPathComponent("FreeYomi/RepositoryCache", isDirectory: true)
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let localRoot = uiTesting
            ? fm.temporaryDirectory.appendingPathComponent("ui-tests-local-\(UUID().uuidString)", isDirectory: true)
            : support.appendingPathComponent("FreeYomi/LocalFiles", isDirectory: true)
        let localStore = LocalLibraryStore(root: localRoot)
        let registry = SourceRegistry.makeDefault(localStore: localStore)

        if uiTesting, let mem = try? DataStore.inMemory() {
            return AppModel(store: mem, registry: registry,
                            catalogCache: fm.temporaryDirectory.appendingPathComponent("ui-tests-repos-\(UUID().uuidString)"),
                            localStore: localStore)
        }

        let dbURL = support.appendingPathComponent("FreeYomi", isDirectory: true)
            .appendingPathComponent("library.sqlite")
        do {
            let store = try DataStore.open(fileURL: dbURL)
            let model = AppModel(store: store, registry: registry, catalogCache: repoCache, localStore: localStore)
            if store.recoveredFromCorruption {
                model.startupNotice = "O banco de dados estava danificado e foi recriado. "
                    + "O arquivo original foi preservado para recuperação manual."
            }
            return model
        } catch {
            // Último recurso: banco temporário para o app abrir mesmo assim.
            let mem = try! DataStore.inMemory()
            let model = AppModel(store: mem, registry: registry,
                                 catalogCache: fm.temporaryDirectory.appendingPathComponent("repos-temp"), localStore: localStore)
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
        migrateRepositories()
        activateNativeSources()
        loadCachedRepositories()
        if !ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            Task {
                await connectServer()
                if settings.refreshRepositoriesOnLaunch && !repositories.isEmpty { await refreshRepositories() }
            }
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

    /// Ativa as fontes das extensões nativas instaladas (cada uma isolada).
    func activateNativeSources() {
        let context = AdapterContext(includeAdult: settings.showNSFWExtensions, dataSaver: settings.sourceDataSaver)
        let failures = extensions.activateInstalledSources(context: context)
        for (id, message) in failures { extensionFailures[id] = message }
        try? service.syncSourceTable()
        reloadExtensionState()
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
            serverExtensions = [:]
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
            await loadServerExtensions()
        } catch {
            serverClient = nil
            serverState = .failed(error.localizedDescription)
            serverExtensions = [:]
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

    func reloadExtensionState() {
        repositories = extensions.repositories()
        installedExtensions = extensions.installedExtensions()
    }

    /// Copia a lista das versões 0.3.x para o banco (uma vez) e avisa se o
    /// repositório que vinha pré-configurado foi retirado.
    private func migrateRepositories() {
        guard !settings.repositoriesMigrated else { reloadExtensionState(); return }
        var s = settings
        let result = extensions.migrateLegacySettings(&s)
        settings = s
        reloadExtensionState()
        if result.removedPreconfigured {
            let notice = "O repositório de extensões que vinha pré-configurado nas versões anteriores foi removido: "
                + "o FreeYomi não traz mais repositórios de fábrica. Para continuar usando um repositório, "
                + "adicione o endereço em Mais › Extensões › Repositórios de extensões."
            startupNotice = startupNotice.map { $0 + "\n\n" + notice } ?? notice
        }
    }

    /// Informações para exibir: banco local, servidor (quando conectado) e índice baixado.
    func repositoryInfo(_ url: String) -> ExtensionRepository {
        let record = repositories.first { RepositoryURL.same($0.url, url) }
        let fromServer = serverRepositories.first { RepositoryURL.same($0.indexURL, url) }
        let fromCatalog = repositoryCatalogs.first { RepositoryURL.same($0.indexURL, url) }?.snapshot
            .map { ExtensionRepository(indexURL: url, index: $0.index) }
        var repo = fromCatalog ?? fromServer ?? ExtensionRepository(indexURL: url, name: RepositoryURL.displayName(url))
        repo.indexURL = url
        if let record {
            if let name = record.name, !name.isEmpty, fromCatalog == nil { repo.name = name }
            if repo.badgeLabel.isEmpty { repo.badgeLabel = record.badgeLabel ?? "" }
            if repo.website == nil { repo.website = record.website }
            if repo.discord == nil { repo.discord = record.discord }
            if repo.signingKey == nil { repo.signingKey = record.signingKey }
            if repo.extensionCount == nil { repo.extensionCount = record.extensionCount }
        }
        if repo.website == nil { repo.website = fromServer?.website }
        if repo.discord == nil { repo.discord = fromServer?.discord }
        return repo
    }

    func repositoryRecord(_ url: String) -> RepositoryRecord? {
        repositories.first { RepositoryURL.same($0.url, url) }
    }

    func repositoryError(_ url: String) -> String? {
        if let error = repositoryCatalogs.first(where: { RepositoryURL.same($0.indexURL, url) })?.error { return error }
        guard let record = repositoryRecord(url), record.lastSyncSucceeded == false else { return nil }
        return record.lastSyncError
    }

    func isOnServer(_ url: String) -> Bool {
        serverRepositories.contains { RepositoryURL.same($0.indexURL, url) }
    }

    func isRepositoryAdded(_ url: String) -> Bool {
        extensions.isAdded(url)
    }

    /// Selo do repositório de origem de uma extensão instalada no servidor (ex.: "KEI").
    func repositoryBadge(forPackage pkg: String) -> String? {
        guard let store = serverExtensionStores[pkg] else { return nil }
        let label = repositoryInfo(store).badgeLabel
        return label.isEmpty ? nil : label
    }

    /// Lê os índices salvos (sem rede).
    func loadCachedRepositories() {
        reloadExtensionState()
        repositoryCatalogs = extensions.cachedCatalogs()
    }

    /// Baixa de novo os índices de todos os repositórios, sincroniza com o
    /// servidor e aplica as atualizações automáticas que o usuário habilitou.
    func refreshRepositories() async {
        guard !isRefreshingRepositories else { return }
        isRefreshingRepositories = true
        defer { isRefreshingRepositories = false }
        repositoryCatalogs = await extensions.refreshAll()
        reloadExtensionState()
        await syncRepositoriesWithServer()
        let auto = await extensions.applyAutoUpdates(repositoryCatalogs)
        if !auto.updated.isEmpty { activateNativeSources() }
        for (id, message) in auto.failed { extensionFailures[id] = message }
        dataVersion += 1
    }

    /// Atualiza um único repositório.
    func refreshRepository(_ url: String) async {
        let result = await extensions.refresh(url)
        if let i = repositoryCatalogs.firstIndex(where: { RepositoryURL.same($0.indexURL, url) }) {
            repositoryCatalogs[i] = result
        } else {
            repositoryCatalogs.append(result)
        }
        reloadExtensionState()
        dataVersion += 1
    }

    /// "Validar": baixa e confere o índice (só metadados; nada é executado nem salvo).
    func previewRepository(_ raw: String) async throws -> RepositoryPreview {
        try await extensions.preview(raw, allowHTTP: settings.allowInsecureRepositoryHTTP)
    }

    /// "Adicionar": grava no banco e, com servidor conectado, envia ao servidor.
    /// Devolve um aviso quando o servidor não aceitou.
    @discardableResult
    func addRepository(_ preview: RepositoryPreview) async throws -> String? {
        try extensions.add(preview)
        reloadExtensionState()
        repositoryCatalogs.removeAll { RepositoryURL.same($0.indexURL, preview.url) }
        repositoryCatalogs.append(RepositoryCatalog(indexURL: preview.url, snapshot: preview.snapshot, error: nil))
        var note: String?
        if let client = serverClient {
            do {
                try await client.addExtensionStore(indexURL: preview.url)
                await syncRepositoriesWithServer()
                await loadServerExtensions()
            } catch {
                note = "Adicionado no app, mas o servidor não aceitou: \(error.localizedDescription)"
            }
        }
        dataVersion += 1
        return note
    }

    /// Remove o repositório do app (e do servidor). Biblioteca, capítulos
    /// baixados e extensões instaladas são preservados.
    @discardableResult
    func removeRepository(_ url: String) async -> RepositoryRemovalSummary? {
        if let client = serverClient,
           let onServer = serverRepositories.first(where: { RepositoryURL.same($0.indexURL, url) }) {
            do {
                try await client.removeExtensionStore(indexURL: onServer.indexURL)
            } catch {
                report(error)
                return nil // sem isso, a próxima sincronização traria o repositório de volta
            }
        }
        do {
            let summary = try extensions.remove(url)
            repositoryCatalogs.removeAll { RepositoryURL.same($0.indexURL, url) }
            serverRepositories.removeAll { RepositoryURL.same($0.indexURL, url) }
            reloadExtensionState()
            if serverClient != nil {
                await syncRepositoriesWithServer()
                await loadServerExtensions()
            }
            dataVersion += 1
            return summary
        } catch {
            report(error)
            return nil
        }
    }

    func moveRepositories(from offsets: IndexSet, to destination: Int) {
        var urls = repositories.map(\.url)
        urls.move(fromOffsets: offsets, toOffset: destination)
        do { try extensions.reorder(urls) } catch { report(error) }
        reloadExtensionState()
        repositoryCatalogs = urls.compactMap { url in repositoryCatalogs.first { $0.indexURL == url } }
    }

    /// Une a lista do app com a do servidor: o que falta no servidor é adicionado
    /// lá; o que só existe no servidor (adicionado por você na interface dele)
    /// entra na lista do app.
    func syncRepositoriesWithServer() async {
        guard let client = serverClient else {
            serverRepositories = []
            serverExtensionStores = [:]
            repositorySyncNote = nil
            return
        }
        do {
            var server = try await client.extensionStores()
            let local = repositories.map(\.url)
            let plan = RepositorySync.plan(local: local, server: server)
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
            for url in plan.mergedLocal where !local.contains(url) {
                _ = try? extensions.addWithoutPreview(url)
            }
            reloadExtensionState()
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

    // MARK: - Extensões

    /// Linhas da tela "Extensões".
    func extensionListings() -> [ExtensionListing] {
        let server: [String: ServerExtensionState]? = serverClient == nil ? nil : serverExtensions.mapValues {
            ServerExtensionState(installed: $0.installed, hasUpdate: $0.hasUpdate, versionName: $0.versionName,
                                 name: $0.name, lang: $0.lang, iconURL: serverClient?.absolute($0.iconUrl) ?? $0.iconUrl)
        }
        return ExtensionListBuilder.build(catalogs: repositoryCatalogs, repositories: repositories,
                                          installed: installedExtensions, adapters: extensions.adapters, server: server,
                                          inProgress: extensionTasks, failures: extensionFailures)
    }

    func loadServerExtensions() async {
        guard let client = serverClient else { serverExtensions = [:]; return }
        do {
            let list = try await client.extensions()
            serverExtensions = Dictionary(list.map { ($0.pkgName, $0) }, uniquingKeysWith: { a, _ in a })
            serverExtensionsError = nil
        } catch {
            serverExtensionsError = error.localizedDescription
        }
    }

    /// Instala ou atualiza: no iPhone (extensão nativa) ou no servidor (Android).
    func installExtension(_ item: ExtensionListing) async {
        guard !extensionTasks.contains(item.packageName) else { return }
        extensionTasks.insert(item.packageName)
        extensionFailures[item.packageName] = nil
        defer { extensionTasks.remove(item.packageName) }
        do {
            switch item.runtime {
            case .device:
                guard let entry = item.catalogEntry, let repo = item.origin.repositoryURL else {
                    throw FYError.notFound("esta extensão não está mais em nenhum repositório")
                }
                try await extensions.install(entry, from: repo)
                activateNativeSources()
            case .server:
                guard let client = serverClient else { throw FYError.unsupported("servidor de extensões desconectado") }
                if case .updateAvailable = item.state {
                    try await client.update(item.packageName)
                } else {
                    try await client.install(item.packageName)
                }
                await loadServerExtensions()
                await connectServer() // atualiza a lista de fontes
            case .none:
                throw FYError.unsupported(item.compatibility.label)
            }
            Haptics.success()
        } catch {
            if let fy = error as? FYError, fy == .cancelled { return }
            extensionFailures[item.packageName] = error.localizedDescription
        }
        dataVersion += 1
    }

    /// Remove a extensão. Os títulos dela continuam na biblioteca.
    func uninstallExtension(_ item: ExtensionListing) async {
        do {
            switch item.runtime {
            case .device:
                try extensions.uninstall(item.packageName)
                extensionFailures[item.packageName] = nil
                activateNativeSources()
            case .server:
                guard let client = serverClient else { return }
                try await client.uninstall(item.packageName)
                await loadServerExtensions()
                await connectServer()
            case .none:
                return
            }
        } catch {
            report(error)
        }
        dataVersion += 1
    }

    func setAutoUpdate(_ id: String, _ value: Bool) {
        mutate { try extensions.setAutoUpdate(id, value) }
        reloadExtensionState()
    }

    /// "Importar extensão": identifica o arquivo sem executá-lo. Manifestos
    /// nativos compatíveis são instalados; APK/JAR são recusados com explicação.
    func importExtensionFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        switch ExtensionFileInspector.inspect(fileAt: url) {
        case .nativeManifest(_, let data):
            do {
                let record = try extensions.installManifestFile(data)
                activateNativeSources()
                Haptics.success()
                alertMessage = "\(record.name) \(record.versionName) foi instalada. As fontes dela aparecem em Explorar › Fontes."
            } catch {
                alertMessage = "Não foi possível instalar: \(error.localizedDescription)"
            }
        case .androidPackage(let kind):
            alertMessage = "\(url.lastPathComponent) é uma extensão Android (\(kind)). O iOS não executa código de "
                + "extensões Android, e o FreeYomi não executa código baixado. Nada foi instalado. "
                + "Para usar extensões Android, conecte um servidor de extensões."
        case .invalidManifest(let message):
            alertMessage = "Manifesto inválido: \(message)"
        case .unknown:
            alertMessage = "Arquivo não reconhecido. Importe um manifesto de extensão do FreeYomi (.json)."
        }
        dataVersion += 1
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
