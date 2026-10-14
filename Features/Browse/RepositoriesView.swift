import SwiftUI
import UIKit
import FYCore
import FYDomain
import FYSources
import FYServices

/// "Repositórios de extensões": lista os repositórios que o USUÁRIO adicionou,
/// com atualização, cópia do endereço, remoção e estado da última sincronização.
///
/// O app não traz nenhum repositório, sugestão ou link de fontes de terceiros.
struct ExtensionRepositoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var addRequest: AddRepositoryRequest?
    @State private var confirmRemove: ExtensionRepository?
    @State private var copiedURL: String?
    @State private var refreshing: Set<String> = []

    var body: some View {
        List {
            Section {
                Text("Repositórios publicam a lista de extensões disponíveis. Adicione o endereço de um repositório em que "
                     + "você confia para ver as fontes que ele oferece. O FreeYomi só baixa a lista (nomes, versões e "
                     + "ícones); nenhum código é executado no iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.repositories.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nenhum repositório", systemImage: "shippingbox")
                    } description: {
                        Text("Você ainda não adicionou nenhum repositório. Insira a URL de um repositório de extensões "
                             + "em que você confia para consultar suas fontes disponíveis.")
                    }
                    .accessibilityIdentifier("repositoriesEmptyState")
                }
            } else {
                Section {
                    ForEach(model.repositories) { record in
                        RepositoryCard(repo: model.repositoryInfo(record.url),
                                       record: record,
                                       error: model.repositoryError(record.url),
                                       onServer: model.serverClient == nil ? nil : model.isOnServer(record.url),
                                       copied: copiedURL == record.url,
                                       isRefreshing: refreshing.contains(record.url) || model.isRefreshingRepositories,
                                       onCopy: { copy(record.url) },
                                       onRefresh: { refresh(record.url) },
                                       onRemove: { confirmRemove = model.repositoryInfo(record.url) })
                    }
                    .onMove { model.moveRepositories(from: $0, to: $1) }
                } header: {
                    Text("\(model.repositories.count) repositório(s)")
                }
            }

            Section {
                Button {
                    addRequest = AddRepositoryRequest(initialURL: "")
                } label: {
                    Label("Adicionar repositório", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("addRepositoryButton")
            } footer: {
                Text("Repositórios e extensões são mantidos por terceiros, sem vínculo com o FreeYomi. Verifique a "
                     + "procedência, as licenças e se você tem permissão para usar o conteúdo das fontes.")
            }

            if !model.repositories.isEmpty {
                Section { serverSummary }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Repositórios de extensões")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.repositories.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshRepositories() }
                    } label: {
                        Label("Atualizar todos", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingRepositories)
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .refreshable { await model.refreshRepositories() }
        .task { model.loadCachedRepositories() }
        .overlay(alignment: .bottom) {
            if model.isRefreshingRepositories {
                HStack(spacing: 8) { ProgressView(); Text("Atualizando repositórios…").font(.subheadline) }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .fyGlass(in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityElement(children: .combine)
            }
        }
        .sheet(item: $addRequest) { AddRepositorySheet(request: $0) }
        .confirmationDialog("Remover repositório?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), titleVisibility: .visible, presenting: confirmRemove) { repo in
            Button("Remover \(repo.name)", role: .destructive) {
                Task {
                    if let summary = await model.removeRepository(repo.indexURL), !summary.keptInstalledExtensions.isEmpty {
                        model.alertMessage = "Repositório removido. Continuam instaladas: "
                            + summary.keptInstalledExtensions.joined(separator: ", ")
                            + ". Elas não receberão mais atualizações; remova-as em Explorar › Extensões, se quiser."
                    }
                }
            }
        } message: { repo in
            Text(removalMessage(repo))
        }
    }

    private func removalMessage(_ repo: ExtensionRepository) -> String {
        let installed = model.installedExtensions.filter { rec in
            rec.repositoryURL.map { RepositoryURL.same($0, repo.indexURL) } ?? false
        }.count
        var text = "Será removido: o endereço e a cópia local da lista de extensões deste repositório."
        if model.serverClient != nil { text += " Ele também sai do seu servidor de extensões." }
        text += "\n\nNÃO serão apagados: sua biblioteca, o histórico, o progresso de leitura e os capítulos baixados."
        if installed > 0 {
            text += " \(installed) extensão(ões) instalada(s) dele continua(m) instalada(s), sem atualizações."
        }
        return text
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
                Label("Extensões Android", systemImage: "server.rack")
                Text("Extensões Android (APK) não rodam no iPhone. Para usá-las, conecte um servidor de extensões "
                     + "que você mesmo instalou; estes repositórios são enviados a ele.")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("Configurar servidor") { ExtensionServerSettingsView() }
                    .font(.callout)
            }
            .padding(.vertical, 2)
        }
    }

    private func refresh(_ url: String) {
        guard !refreshing.contains(url) else { return }
        refreshing.insert(url)
        Task {
            await model.refreshRepository(url)
            refreshing.remove(url)
        }
    }

    private func copy(_ url: String) {
        UIPasteboard.general.string = url
        Haptics.success()
        copiedURL = url
        UIAccessibility.post(notification: .announcement, argument: "Endereço copiado")
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedURL == url { copiedURL = nil }
        }
    }
}

/// Cartão de um repositório: nome + selo, endereço, sincronização e ações.
struct RepositoryCard: View {
    let repo: ExtensionRepository
    let record: RepositoryRecord?
    let error: String?
    /// `nil` sem servidor; `true`/`false` se o servidor já tem o repositório.
    let onServer: Bool?
    let copied: Bool
    let isRefreshing: Bool
    let onCopy: () -> Void
    let onRefresh: () -> Void
    let onRemove: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repo.name).font(.headline)
                if !repo.badgeLabel.isEmpty { RepoBadge(text: repo.badgeLabel) }
                if RepositoryURL.isInsecure(repo.indexURL) {
                    Label("HTTP", systemImage: "lock.open.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Conexão sem criptografia")
                }
                Spacer()
                Menu {
                    Button { onRefresh() } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                    Button { onCopy() } label: { Label("Copiar endereço", systemImage: "doc.on.doc") }
                    if let site = repo.websiteURL {
                        Button { openURL(site) } label: { Label("Abrir site do repositório", systemImage: "safari") }
                    }
                    Divider()
                    Button(role: .destructive) { onRemove() } label: { Label("Remover", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
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
                .fySecondaryButton()
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Atualizar", systemImage: "arrow.clockwise")
                    }
                }
                .fySecondaryButton()
                .disabled(isRefreshing)
                .accessibilityLabel(isRefreshing ? "Atualizando \(repo.name)" : "Atualizar \(repo.name)")
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if let n = repo.extensionCount {
                        Label("\(n) extensões", systemImage: "puzzlepiece.extension")
                    }
                    if let format = record?.format.flatMap(RepositoryIndexFormat.init(rawValue:)) {
                        Text(format.label)
                    }
                }
                syncStatus
                if let onServer {
                    Label(onServer ? "No servidor" : "Não está no servidor",
                          systemImage: onServer ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(onServer ? Color.green : Color.orange)
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Erro na última atualização: \(error)")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let date = record?.lastSyncAt {
            if record?.lastSyncSucceeded == false {
                Label {
                    Text("Falhou \(date, style: .relative) atrás — exibindo a última cópia salva")
                } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
            } else {
                Label {
                    Text("Sincronizado \(date, style: .relative) atrás")
                } icon: { Image(systemName: "checkmark.circle") }
            }
        } else {
            Label("Ainda não sincronizado", systemImage: "clock")
        }
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
    var id: String { "add:" + initialURL }
}

/// Adicionar repositório: colar o endereço, "Validar" (baixa e confere o
/// índice) e "Adicionar" (só depois de validado). Nada é salvo antes disso.
struct AddRepositorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AddRepositoryRequest

    @State private var text = ""
    @State private var task: Task<Void, Never>?
    @State private var checking = false
    @State private var adding = false
    @State private var errorMessage: String?
    @State private var preview: RepositoryPreview?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/index.min.json", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .font(.callout.monospaced())
                        .focused($fieldFocused)
                        .onSubmit { validate() }
                        .accessibilityLabel("URL do repositório")
                        .accessibilityIdentifier("repositoryURLField")
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            guard let first = strings.first else { return }
                            Task { @MainActor in text = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        Spacer()
                        if checking {
                            ProgressView().accessibilityLabel("Validando")
                            Button("Parar") { task?.cancel() }
                                .accessibilityHint("Cancela a validação em andamento")
                        } else {
                            Button("Validar") { validate() }
                                .fySecondaryButton()
                                .disabled(trimmed.isEmpty)
                                .accessibilityIdentifier("validateRepository")
                        }
                    }
                } header: {
                    Text("Endereço do repositório")
                } footer: {
                    Text("Aceita index.min.json, repo.json, index.json, index.pb ou um índice do FreeYomi, por HTTPS. "
                         + "Links \"Adicionar repositório\" de sites também abrem esta tela, sempre pedindo confirmação.")
                }

                if model.settings.allowInsecureRepositoryHTTP {
                    Section {
                        Label("Repositórios em HTTP estão permitidos nas configurações. Em HTTP, qualquer pessoa na "
                              + "mesma rede pode ler ou alterar a lista baixada. O iOS só permite HTTP na rede local.",
                              systemImage: "lock.open.trianglebadge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Erro: \(errorMessage)")
                    }
                }

                if let preview {
                    previewSection(preview)
                }
            }
            .navigationTitle("Adicionar repositório")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { task?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        add()
                    } label: {
                        if adding { ProgressView() } else { Text("Adicionar").bold() }
                    }
                    .disabled(preview == nil || adding || checking)
                    .accessibilityIdentifier("confirmAddRepository")
                }
            }
            .onAppear {
                if text.isEmpty && !request.initialURL.isEmpty {
                    text = request.initialURL
                    validate()
                } else if request.initialURL.isEmpty {
                    fieldFocused = true
                }
            }
            .onChange(of: text) { _, new in
                if let p = preview, !RepositoryURL.same(p.url, new) { preview = nil }
            }
            .onDisappear { task?.cancel() }
        }
    }

    @ViewBuilder
    private func previewSection(_ p: RepositoryPreview) -> some View {
        let repo = p.repository
        let index = p.snapshot.index
        let compatible = index.extensions.filter { CompatibilityResolver.resolve($0, adapters: model.extensions.adapters).isCompatible }.count
        let android = index.extensions.filter { !$0.isNative }.count
        let adult = index.extensions.filter { $0.contentWarning == .nsfw }.count
        Section {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text(repo.name).font(.headline)
                if !repo.badgeLabel.isEmpty { RepoBadge(text: repo.badgeLabel) }
            }
            LabeledContent("Formato", value: index.format.label)
            LabeledContent("Extensões", value: "\(index.extensions.count)")
            LabeledContent("Compatíveis com iOS", value: "\(compatible)")
            if android > 0 { LabeledContent("Android (exigem servidor)", value: "\(android)") }
            if adult > 0 { LabeledContent("Marcadas como 18+", value: "\(adult)") }
            if index.skippedEntries > 0 {
                LabeledContent("Entradas ignoradas (incompletas)", value: "\(index.skippedEntries)")
            }
            if let site = repo.websiteURL { LabeledContent("Site", value: site.host ?? site.absoluteString) }
            if let key = repo.signingKeyFingerprint {
                LabeledContent("Chave de assinatura") { Text(key).font(.caption.monospaced()) }
            }
            if p.allowsInsecureHTTP {
                Label("Este repositório usa HTTP, sem criptografia.", systemImage: "lock.open.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Índice válido")
        } footer: {
            Text("Toque em Adicionar para salvar. "
                 + (model.serverClient == nil
                    ? "Extensões Android aparecerão como incompatíveis até você conectar um servidor de extensões."
                    : "Ele também será enviado ao seu servidor de extensões."))
        }
    }

    private func validate() {
        guard !trimmed.isEmpty, !checking else { return }
        errorMessage = nil
        preview = nil
        checking = true
        let raw = trimmed
        task = Task {
            defer { checking = false }
            do {
                let result = try await model.previewRepository(raw)
                if !Task.isCancelled { preview = result }
                UIAccessibility.post(notification: .announcement, argument: "Índice válido: \(result.repository.name)")
            } catch {
                if let fy = error as? FYError, fy == .cancelled { return }
                if Task.isCancelled { errorMessage = "Validação cancelada."; return }
                errorMessage = error.localizedDescription
                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            }
        }
    }

    private func add() {
        guard let p = preview, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                let note = try await model.addRepository(p)
                Haptics.success()
                dismiss()
                if let note { model.alertMessage = note }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
