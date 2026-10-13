import SwiftUI
import UIKit
import FYCore
import FYDomain
import FYSources

/// "Repositórios de extensões": lista, copia, abre contato, adiciona e remove
/// repositórios (index.pb / repo.json), como no Tachimanga e no Mihon.
///
/// Com servidor conectado, a lista é sincronizada com o Suwayomi-Server, que
/// baixa e executa as extensões. Sem servidor, os repositórios alimentam o
/// catálogo (somente metadados).
struct ExtensionRepositoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var addRequest: AddRepositoryRequest?
    @State private var confirmRemove: ExtensionRepository?
    @State private var copiedURL: String?

    var body: some View {
        List {
            Section {
                ForEach(model.settings.extensionRepositories, id: \.self) { url in
                    RepositoryCard(repo: model.repositoryInfo(url),
                                   error: model.repositoryError(url),
                                   onServer: model.serverClient == nil ? nil : model.isOnServer(url),
                                   copied: copiedURL == url,
                                   onCopy: { copy(url) },
                                   onRemove: { confirmRemove = model.repositoryInfo(url) })
                }
                .onMove { model.moveRepositories(from: $0, to: $1) }
            } footer: {
                if model.settings.extensionRepositories.isEmpty {
                    Text("Nenhum repositório. Toque em \"Adicionar repositório\".")
                }
            }

            Section {
                Button {
                    addRequest = AddRepositoryRequest(initialURL: "")
                } label: {
                    Label("Adicionar repositório", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("addRepositoryButton")
                Button {
                    addRequest = AddRepositoryRequest(initialURL: "", focusSuggestions: true)
                } label: {
                    Label("Encontrar repositório", systemImage: "magnifyingglass")
                }
            } footer: {
                Text("Adicione apenas repositórios em que você confia. "
                     + "Ao adicionar, o FreeYomi baixa só o índice (nomes, versões e ícones); nenhum código roda no iPhone.")
            }

            Section {
                serverSummary
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Repositórios de extensões")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .refreshable { await model.refreshRepositories() }
        .task {
            model.loadCachedRepositories()
            if model.repositoryCatalogs.contains(where: { $0.snapshot == nil }) {
                await model.refreshRepositories()
            }
        }
        .overlay(alignment: .bottom) {
            if model.isRefreshingRepositories {
                HStack(spacing: 8) { ProgressView(); Text("Atualizando repositórios…").font(.subheadline) }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .fyGlass(in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .sheet(item: $addRequest) { AddRepositorySheet(request: $0) }
        .confirmationDialog("Remover repositório?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), titleVisibility: .visible, presenting: confirmRemove) { repo in
            Button("Remover \(repo.name)", role: .destructive) {
                Task { await model.removeRepository(repo.indexURL) }
            }
        } message: { _ in
            Text(model.serverClient == nil
                 ? "As extensões dele deixam de aparecer no catálogo."
                 : "Também será removido do servidor. Novas extensões e atualizações dele deixam de aparecer.")
        }
    }

    @ViewBuilder
    private var serverSummary: some View {
        if model.serverClient != nil {
            Label("Sincronizado com o servidor de extensões", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
            if let note = model.repositorySyncNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Sem servidor de extensões", systemImage: "server.rack")
                Text("Para instalar extensões destes repositórios e ler pelas fontes delas, conecte o Suwayomi-Server. "
                     + "Os repositórios desta lista são enviados a ele automaticamente.")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("Conectar servidor") { ExtensionServerSettingsView() }
                    .font(.callout)
            }
            .padding(.vertical, 2)
        }
    }

    private func copy(_ url: String) {
        UIPasteboard.general.string = url
        Haptics.success()
        copiedURL = url
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedURL == url { copiedURL = nil }
        }
    }
}

/// Cartão de um repositório: nome + selo, endereço, Copiar / Discord / Site e menu ⋯.
struct RepositoryCard: View {
    let repo: ExtensionRepository
    let error: String?
    /// `nil` sem servidor; `true`/`false` se o servidor já tem o repositório.
    let onServer: Bool?
    let copied: Bool
    let onCopy: () -> Void
    let onRemove: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repo.name).font(.headline)
                if !repo.badgeLabel.isEmpty { RepoBadge(text: repo.badgeLabel) }
                Spacer()
                Menu {
                    Button { onCopy() } label: { Label("Copiar endereço", systemImage: "doc.on.doc") }
                    if let site = repo.websiteURL {
                        Button { openURL(site) } label: { Label("Abrir site", systemImage: "safari") }
                    }
                    if let discord = repo.discordURL {
                        Button { openURL(discord) } label: { Label("Discord", systemImage: "bubble.left.and.bubble.right") }
                    }
                    Divider()
                    Button(role: .destructive) { onRemove() } label: { Label("Remover", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("Mais opções de \(repo.name)")
            }

            Text(repo.indexURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(action: onCopy) {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                if let discord = repo.discordURL {
                    Button { openURL(discord) } label: { Label("Discord", systemImage: "bubble.left.and.bubble.right") }
                        .buttonStyle(.bordered)
                } else if let site = repo.websiteURL {
                    Button { openURL(site) } label: { Label("Site", systemImage: "safari") }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)

            HStack(spacing: 10) {
                if let n = repo.extensionCount {
                    Label("\(n) extensões", systemImage: "puzzlepiece.extension").labelStyle(.titleAndIcon)
                }
                if let onServer {
                    Label(onServer ? "No servidor" : "Não está no servidor",
                          systemImage: onServer ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(onServer ? Color.green : Color.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error {
                Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RepoBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(FYColor.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(FYColor.accent)
            .accessibilityLabel("Repositório \(text)")
    }
}

struct AddRepositoryRequest: Identifiable, Hashable {
    var initialURL: String
    var focusSuggestions = false
    var id: String { (focusSuggestions ? "find:" : "add:") + initialURL }
}

/// Adicionar repositório: colar/digitar o endereço (ou escolher uma sugestão),
/// verificar o índice e confirmar vendo nome, selo, total de extensões e a
/// impressão digital da chave de assinatura.
struct AddRepositorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AddRepositoryRequest

    @State private var text = ""
    @State private var checking = false
    @State private var adding = false
    @State private var errorMessage: String?
    @State private var preview: (url: String, snapshot: CatalogSnapshot)?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        TextField("https://…/index.pb", text: $text, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.callout.monospaced())
                            .onSubmit { Task { await check() } }
                            .accessibilityIdentifier("repositoryURLField")
                        HStack {
                            PasteButton(payloadType: String.self) { strings in
                                guard let first = strings.first else { return }
                                Task { @MainActor in
                                    text = first.trimmingCharacters(in: .whitespacesAndNewlines)
                                    await check()
                                }
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                            Spacer()
                            Button {
                                Task { await check() }
                            } label: {
                                if checking { ProgressView() } else { Text("Verificar") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                        }
                    } header: {
                        Text("Endereço do repositório")
                    } footer: {
                        Text("Aceita o endereço do index.pb ou do repo.json, apenas HTTPS. "
                             + "Links \"Adicionar ao Mihon/Tachiyomi\" de sites de repositórios também abrem esta tela.")
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }

                    if let p = preview {
                        previewSection(p)
                    }

                    Section {
                        ForEach(RepositorySuggestion.all) { s in
                            let added = model.isRepositoryAdded(s.indexURL)
                            Button {
                                text = s.indexURL
                                Task { await check() }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.name).foregroundStyle(.primary)
                                        Text(s.note).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if added {
                                        Text("Adicionado").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .disabled(added)
                        }
                    } header: {
                        Text("Encontrar repositório")
                    } footer: {
                        Text("Repositórios mantidos pela comunidade, sem vínculo com o FreeYomi. "
                             + "Também é possível colar o endereço de qualquer outro.")
                    }
                    .id("suggestions")
                }
                .onAppear {
                    if request.focusSuggestions {
                        DispatchQueue.main.async { withAnimation { proxy.scrollTo("suggestions", anchor: .top) } }
                    }
                }
            }
            .navigationTitle("Adicionar repositório")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .onAppear {
                if text.isEmpty && !request.initialURL.isEmpty {
                    text = request.initialURL
                    Task { await check() }
                }
            }
            .onChange(of: text) { _, new in
                if let p = preview, !RepositoryURL.same(p.url, new) { preview = nil }
            }
        }
    }

    @ViewBuilder
    private func previewSection(_ p: (url: String, snapshot: CatalogSnapshot)) -> some View {
        let repo = ExtensionRepository(indexURL: p.url, index: p.snapshot.index)
        let ptBR = p.snapshot.index.extensions.filter { $0.languages.contains("pt-BR") }.count
        let adult = p.snapshot.index.extensions.filter { $0.contentWarning == .nsfw }.count
        Section {
            HStack(spacing: 8) {
                Text(repo.name).font(.headline)
                if !repo.badgeLabel.isEmpty { RepoBadge(text: repo.badgeLabel) }
            }
            LabeledContent("Extensões", value: "\(repo.extensionCount ?? 0)")
            LabeledContent("Com fontes em português (Brasil)", value: "\(ptBR)")
            if adult > 0 { LabeledContent("Marcadas como 18+", value: "\(adult)") }
            if let site = repo.websiteURL { LabeledContent("Site", value: site.host ?? site.absoluteString) }
            if let key = repo.signingKeyFingerprint {
                LabeledContent("Chave de assinatura") { Text(key).font(.caption.monospaced()) }
            }
            Button {
                Task { await add(p) }
            } label: {
                HStack {
                    Spacer()
                    if adding { ProgressView() } else { Text("Adicionar").bold() }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(adding)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityIdentifier("confirmAddRepository")
        } header: {
            Text("Repositório encontrado")
        } footer: {
            Text(model.serverClient == nil
                 ? "As extensões dele aparecerão no catálogo. Para instalá-las, conecte o servidor de extensões."
                 : "Também será adicionado ao seu servidor; as extensões dele aparecerão em Explorar › Extensões para instalar.")
        }
    }

    private func check() async {
        errorMessage = nil
        preview = nil
        checking = true
        defer { checking = false }
        do {
            preview = try await model.previewRepository(text)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ p: (url: String, snapshot: CatalogSnapshot)) async {
        adding = true
        defer { adding = false }
        let note = await model.addRepository(url: p.url, snapshot: p.snapshot)
        Haptics.success()
        dismiss()
        if let note { model.alertMessage = note }
    }
}
