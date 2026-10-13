import SwiftUI
import FYSources
import FYCore
import FYDomain
import FYData
import FYServices

/// Catálogo de extensões (índice público Keiyoushi).
///
/// Apenas METADADOS são baixados. Nenhum APK/JAR é baixado ou executado.
/// Cada extensão é classificada honestamente: "Requer Android" até que um
/// adaptador nativo Swift seja escrito para ela.
struct ExtensionCatalogView: View {
    @Environment(AppModel.self) private var model

    @State private var snapshot: CatalogSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var search = ""
    @State private var language: String = "pt-BR"

    var body: some View {
        List {
            statusSection
            if let snapshot {
                let filtered = filter(snapshot.index.extensions)
                Section {
                    ForEach(filtered) { ExtensionRow(ext: $0) }
                } header: {
                    Text("\(filtered.count) extensões")
                } footer: {
                    Text("Extensões do catálogo são programas Kotlin para Android e não podem ser executadas no iOS. "
                         + "O FreeYomi as lista para transparência e para orientar quais adaptadores nativos criar.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Pesquisar extensões")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Idioma", selection: $language) {
                        Text("Todos").tag("")
                        ForEach(availableLanguages, id: \.self) { Text(LanguageName.display($0)).tag($0) }
                    }
                } label: { Label("Idioma", systemImage: "character.bubble") }
            }
        }
        .refreshable { await refresh() }
        .task {
            if snapshot == nil {
                snapshot = try? model.catalog.loadCache()
                if snapshot == nil { await refresh() }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if isLoading {
                HStack { ProgressView(); Text("Baixando índice…").foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "wifi.exclamationmark").foregroundStyle(.orange).font(.callout)
            }
            if let s = snapshot {
                LabeledContent("Repositório", value: "\(s.index.name) (\(s.index.badgeLabel))")
                LabeledContent("Origem", value: URL(string: s.sourceURL)?.host ?? s.sourceURL)
                LabeledContent("Sincronizado", value: s.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                if s.isFromCache {
                    Text(s.networkError.map { "Mostrando cópia local. \($0)" } ?? "Mostrando cópia local.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !isLoading && errorMessage == nil {
                Text("Nenhum catálogo baixado ainda.").foregroundStyle(.secondary)
            }
            Button {
                Task { await refresh() }
            } label: { Label("Atualizar catálogo", systemImage: "arrow.clockwise") }
            .disabled(isLoading)
        } header: {
            Text("Catálogo")
        }
    }

    private var availableLanguages: [String] {
        guard let s = snapshot else { return [] }
        return Array(Set(s.index.extensions.flatMap(\.languages))).sorted()
    }

    private func filter(_ list: [CatalogExtension]) -> [CatalogExtension] {
        list.filter { e in
            (model.settings.showNSFWExtensions || e.contentWarning != .nsfw)
                && (language.isEmpty || e.languages.contains(language))
                && (search.isEmpty || e.name.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let s = try await model.catalog.refresh(from: model.settings.catalogURL)
            snapshot = s
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ExtensionRow: View {
    let ext: CatalogExtension

    var body: some View {
        let compat = CompatibilityResolver.resolve(ext)
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: ext.iconURL)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name).font(.body)
                Text("v\(ext.versionName) · \(ext.languages.prefix(4).map(LanguageName.display).joined(separator: ", "))"
                     + (ext.languages.count > 4 ? " +\(ext.languages.count - 4)" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    pill(compat.label, color: compat == .requiresAndroid ? .orange : .green)
                    if ext.contentWarning == .nsfw || ext.contentWarning == .mixed {
                        pill(ext.contentWarning.label, color: .red)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
