import SwiftUI
import UniformTypeIdentifiers
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Explorar › Extensões.
///
/// Lista SOMENTE extensões dos repositórios que o usuário adicionou ou de
/// arquivos que ele importou. Cada item mostra origem, compatibilidade e
/// estado, com a ação correspondente:
/// - extensões nativas compatíveis: instaladas no iPhone (manifesto + adaptador);
/// - extensões Android: incompatíveis com iOS; instaláveis só no servidor de
///   extensões do usuário, quando conectado.
struct ExtensionsView: View {
    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var language = ""
    @State private var stateFilter: ExtensionStateFilter = .all
    @State private var repositoryFilter = ""
    @State private var running: [String: Task<Void, Never>] = [:]
    @State private var detail: ExtensionListing?
    @State private var confirmUninstall: ExtensionListing?
    @State private var importing = false

    var body: some View {
        let all = model.extensionListings()
        let visible = filter(all)
        let updates = visible.filter { $0.state.filter == .updates }
        let installed = visible.filter { $0.state.filter == .installed || $0.state.filter == .failed }
        let available = visible.filter { $0.state.filter == .available }
        let incompatible = visible.filter { $0.state.filter == .incompatible }
        let hasAndroid = all.contains { $0.compatibility == .requiresAndroid }

        List {
            Section {
                RepositoriesLinkRow()
                Button {
                    importing = true
                } label: {
                    Label("Importar extensão de um arquivo", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("importExtensionButton")
            }

            if model.repositories.isEmpty && model.installedExtensions.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nenhuma extensão", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("As extensões aparecem aqui depois que você adiciona um repositório em que confia, "
                             + "ou importa um arquivo de extensão.")
                    }
                }
            } else {
                statusSection
                if hasAndroid && model.serverClient == nil { ConnectServerBanner() }
                if visible.isEmpty && !all.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: search)
                    }
                }
                group("Atualizações", updates)
                group("Instaladas", installed)
                group("Disponíveis", available)
                if !incompatible.isEmpty {
                    Section {
                        ForEach(incompatible) { row($0) }
                    } header: {
                        Text("Incompatíveis (\(incompatible.count))")
                    } footer: {
                        Text("Extensões Android (APK/JAR) contêm código para Android e não rodam no iPhone. "
                             + "O FreeYomi não baixa nem executa esse código.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Pesquisar extensões")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu(all) }
        }
        .refreshable { await model.refreshRepositories() }
        .task {
            if model.repositoryCatalogs.isEmpty { model.loadCachedRepositories() }
            if model.serverClient != nil && model.serverExtensions.isEmpty { await model.loadServerExtensions() }
        }
        .onDisappear { for t in running.values { t.cancel() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importExtensionFile(url) }
        }
        .sheet(item: $detail) { ExtensionDetailSheet(listing: $0) }
        .confirmationDialog("Remover extensão?", isPresented: Binding(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }
        ), titleVisibility: .visible, presenting: confirmUninstall) { item in
            Button("Remover \(item.name)", role: .destructive) { Task { await model.uninstallExtension(item) } }
        } message: { item in
            Text(item.runtime == .server
                 ? "A extensão será removida do servidor. Títulos desta fonte continuam na biblioteca."
                 : "As fontes desta extensão deixam de aparecer. Títulos, progresso e capítulos baixados continuam na biblioteca.")
        }
    }

    // MARK: Seções

    @ViewBuilder
    private func group(_ title: String, _ items: [ExtensionListing]) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") { ForEach(items) { row($0) } }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        let failed = model.repositoryCatalogs.filter(\.isUnavailable)
        let neverLoaded = model.repositoryCatalogs.filter { $0.snapshot == nil && $0.error == nil }
        if model.isRefreshingRepositories || !failed.isEmpty || !neverLoaded.isEmpty || model.serverExtensionsError != nil {
            Section {
                if model.isRefreshingRepositories {
                    HStack { ProgressView(); Text("Atualizando repositórios…").foregroundStyle(.secondary) }
                }
                ForEach(failed) { rc in
                    Label {
                        Text("\(model.repositoryInfo(rc.indexURL).name): \(rc.error ?? "")"
                             + (rc.snapshot != nil ? " Exibindo a última cópia salva, que pode estar desatualizada." : ""))
                    } icon: { Image(systemName: "wifi.exclamationmark") }
                        .foregroundStyle(.orange).font(.callout)
                }
                if !neverLoaded.isEmpty && !model.isRefreshingRepositories {
                    Button("Baixar a lista de \(neverLoaded.count) repositório(s)") {
                        Task { await model.refreshRepositories() }
                    }
                }
                if let error = model.serverExtensionsError {
                    Label("Servidor: \(error)", systemImage: "server.rack").foregroundStyle(.orange).font(.callout)
                }
            }
        }
    }

    // MARK: Linha

    private func row(_ item: ExtensionListing) -> some View {
        HStack(spacing: 12) {
            ExtensionIcon(url: item.iconURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body).lineLimit(1)
                Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    OriginBadge(origin: item.origin)
                    StatePill(state: item.state, runtime: item.runtime)
                    if item.isNSFW { Pill(text: "18+", color: .red) }
                }
            }
            Spacer(minLength: 4)
            action(item)
        }
        .contentShape(Rectangle())
        .onTapGesture { detail = item }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Detalhes") { detail = item }
    }

    private func subtitle(_ item: ExtensionListing) -> String {
        var parts = ["v\(item.versionName)"]
        let langs = item.languages.prefix(3).map(LanguageName.display)
        if !langs.isEmpty { parts.append(langs.joined(separator: ", ") + (item.languages.count > 3 ? " +\(item.languages.count - 3)" : "")) }
        if let installed = item.installedVersionName, installed != item.versionName { parts.append("instalada v\(installed)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func action(_ item: ExtensionListing) -> some View {
        switch item.state {
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                if running[item.packageName] != nil {
                    Button { running[item.packageName]?.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancelar download de \(item.name)")
                }
            }
        case .available:
            Button("Instalar") { start(item) }
                .fySecondaryButton().controlSize(.small)
                .accessibilityLabel(item.runtime == .server ? "Instalar \(item.name) no servidor" : "Instalar \(item.name)")
        case .updateAvailable:
            Button("Atualizar") { start(item) }
                .fyProminentButton().controlSize(.small)
        case .installed:
            Button(role: .destructive) { confirmUninstall = item } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remover \(item.name)")
        case .failed:
            if item.catalogEntry != nil || item.runtime == .server {
                Button("Tentar de novo") { start(item) }
                    .fySecondaryButton().controlSize(.small)
            } else {
                Button(role: .destructive) { confirmUninstall = item } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remover \(item.name)")
            }
        case .incompatible:
            Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityHidden(true)
        case .repositoryUnavailable:
            Image(systemName: "icloud.slash").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private func start(_ item: ExtensionListing) {
        guard running[item.packageName] == nil else { return }
        running[item.packageName] = Task {
            await model.installExtension(item)
            running[item.packageName] = nil
        }
    }

    // MARK: Filtros

    private func filterMenu(_ all: [ExtensionListing]) -> some View {
        let languages = Array(Set(all.flatMap(\.languages))).sorted()
        let repos = model.repositories
        let active = !language.isEmpty || stateFilter != .all || !repositoryFilter.isEmpty
        return Menu {
            Picker("Idioma", selection: $language) {
                Text("Todos os idiomas").tag("")
                ForEach(languages, id: \.self) { Text(LanguageName.display($0)).tag($0) }
            }
            Picker("Estado", selection: $stateFilter) {
                ForEach(ExtensionStateFilter.allCases) { Text($0.label).tag($0) }
            }
            Picker("Repositório", selection: $repositoryFilter) {
                Text("Todas as origens").tag("")
                ForEach(repos) { Text(model.repositoryInfo($0.url).name).tag($0.url) }
                Text("Arquivos importados").tag("#imported")
                Text("Repositórios removidos").tag("#removed")
                if model.serverClient != nil { Text("Somente no servidor").tag("#server") }
            }
            if active {
                Button("Limpar filtros", role: .destructive) {
                    language = ""; stateFilter = .all; repositoryFilter = ""
                }
            }
        } label: {
            Label("Filtros", systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(active ? "Filtros (ativos)" : "Filtros")
    }

    private func filter(_ list: [ExtensionListing]) -> [ExtensionListing] {
        list.filter { e in
            if !model.settings.showNSFWExtensions && e.isNSFW && e.installedVersionName == nil { return false }
            if !language.isEmpty && !e.languages.contains(language) { return false }
            if stateFilter != .all && e.state.filter != stateFilter { return false }
            if !repositoryFilter.isEmpty {
                switch repositoryFilter {
                case "#imported": if e.origin != .importedFile { return false }
                case "#server": if e.origin != .serverOnly { return false }
                case "#removed":
                    if case .removedRepository = e.origin {} else { return false }
                default:
                    guard case .repository(let url, _, _) = e.origin, RepositoryURL.same(url, repositoryFilter) else { return false }
                }
            }
            if !search.isEmpty && !e.name.localizedCaseInsensitiveContains(search)
                && !e.packageName.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Componentes

/// Atalho para a tela de repositórios.
struct RepositoriesLinkRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink {
            ExtensionRepositoriesView()
        } label: {
            LabeledContent {
                Text("\(model.repositories.count)").foregroundStyle(.secondary)
            } label: {
                Label("Repositórios de extensões", systemImage: "shippingbox")
            }
        }
        .accessibilityIdentifier("repositoriesLink")
    }
}

struct ExtensionIcon: View {
    let url: String
    var body: some View {
        Group {
            if let u = URL(string: url), u.scheme?.lowercased() == "https" {
                AsyncImage(url: u) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "puzzlepiece.extension")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct StatePill: View {
    let state: ExtensionRowState
    let runtime: ExtensionRuntime

    var body: some View {
        Pill(text: text, color: color)
    }

    private var text: String {
        switch state {
        case .available: return runtime == .server ? "Disponível no servidor" : "Disponível"
        case .installed: return runtime == .server ? "Instalada no servidor" : "Instalada"
        case .repositoryUnavailable: return runtime == .server ? "Servidor sem este repositório" : state.label
        default: return state.label
        }
    }

    private var color: Color {
        switch state {
        case .available: return FYColor.accent
        case .downloading: return .blue
        case .installed: return .green
        case .updateAvailable: return .purple
        case .incompatible: return .secondary
        case .failed: return .red
        case .repositoryUnavailable: return .orange
        }
    }
}

struct OriginBadge: View {
    let origin: ExtensionOrigin
    var body: some View {
        switch origin {
        case .repository(_, let name, let badge):
            Text(badge.isEmpty ? name : badge)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(FYColor.accent.opacity(0.18), in: Capsule())
                .foregroundStyle(FYColor.accent)
                .accessibilityLabel("Repositório \(name)")
        case .removedRepository:
            Pill(text: "Origem removida", color: .orange)
        case .importedFile:
            Pill(text: "Arquivo", color: .teal)
        case .serverOnly:
            Pill(text: "Servidor", color: .teal)
        }
    }
}

/// Detalhes de uma extensão: metadados, fontes, compatibilidade e preferências.
struct ExtensionDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let listing: ExtensionListing

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ExtensionIcon(url: listing.iconURL)
                        VStack(alignment: .leading) {
                            Text(listing.name).font(.headline)
                            Text(listing.packageName).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("Estado", value: listing.state.label)
                    LabeledContent("Compatibilidade", value: listing.compatibility.label)
                    LabeledContent("Versão disponível", value: listing.versionName)
                    if let installed = listing.installedVersionName {
                        LabeledContent("Versão instalada", value: installed)
                    }
                    LabeledContent("Origem", value: listing.origin.label)
                    if let url = listing.origin.repositoryURL {
                        Text(url).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !listing.languages.isEmpty {
                        LabeledContent("Idiomas", value: listing.languages.map(LanguageName.display).joined(separator: ", "))
                    }
                    if listing.contentWarning != .unspecified {
                        LabeledContent("Conteúdo", value: listing.contentWarning.label)
                    }
                    if let verified = listing.integrityVerified {
                        LabeledContent("Integridade", value: verified ? "SHA-256 conferido" : "Sem hash publicado")
                    }
                }

                if case .incompatible(let reason) = listing.state {
                    Section("Por que é incompatível") { Text(reason).font(.callout) }
                }
                if case .failed(let reason) = listing.state {
                    Section("Falha") { Text(reason).font(.callout).foregroundStyle(.red) }
                }

                if let entry = listing.catalogEntry {
                    Section("Arquivos") {
                        if let native = entry.native {
                            LabeledContent("Adaptador", value: "\(native.adapter) v\(native.adapterVersion)")
                            downloadRow("Manifesto", native.manifestURL)
                            if let hash = native.sha256 {
                                LabeledContent("SHA-256") { Text(hash).font(.caption2.monospaced()).textSelection(.enabled) }
                            }
                        } else {
                            if !entry.extensionLib.isEmpty { LabeledContent("extensions-lib", value: entry.extensionLib) }
                            if !entry.apkURL.isEmpty { downloadRow("APK (Android)", entry.apkURL) }
                            if let jar = entry.jarURL, !jar.isEmpty { downloadRow("JAR", jar) }
                        }
                    }
                    if !entry.sources.isEmpty {
                        Section("Fontes (\(entry.sources.count))") {
                            ForEach(Array(entry.sources.enumerated()), id: \.offset) { _, source in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                    Text([LanguageName.display(source.language), source.homeURL]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let message = source.message, !message.isEmpty {
                                        Text(message).font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }

                if listing.runtime == .device, let record = model.installedExtensions.first(where: { $0.id == listing.packageName }) {
                    Section {
                        Toggle("Atualizar automaticamente", isOn: Binding(
                            get: { record.autoUpdate },
                            set: { model.setAutoUpdate(record.id, $0) }))
                        LabeledContent("Instalada em") { Text(record.installedAt, style: .date) }
                        LabeledContent("Atualizada em") { Text(record.updatedAt, style: .date) }
                    } footer: {
                        Text("Atualizações automáticas são aplicadas quando os repositórios são atualizados. "
                             + "Os títulos da biblioteca são mantidos.")
                    }
                }
            }
            .navigationTitle("Extensão")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }

    private func downloadRow(_ title: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(url).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }
    }
}
