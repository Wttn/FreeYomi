import SwiftUI
import FYSources
import FYCore
import FYDomain
import FYData
import FYServices

/// Catálogo de extensões de todos os repositórios configurados (sem servidor).
///
/// Apenas METADADOS são baixados. Nenhum APK/JAR é baixado ou executado.
/// Cada extensão é classificada honestamente: "Requer Android" até que um
/// adaptador nativo Swift seja escrito para ela, ou até conectar um servidor.
struct ExtensionCatalogView: View {
    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var language: String = "pt-BR"

    struct Item: Identifiable {
        let ext: CatalogExtension
        let badge: String
        let repoURL: String
        var id: String { repoURL + "|" + ext.packageName }
    }

    private var items: [Item] {
        model.repositoryCatalogs.flatMap { rc -> [Item] in
            guard let s = rc.snapshot else { return [] }
            return s.index.extensions.map { Item(ext: $0, badge: s.index.badgeLabel, repoURL: rc.indexURL) }
        }
    }

    var body: some View {
        let all = items
        let filtered = filter(all)
        List {
            ConnectServerBanner()
            RepositoriesLinkSection()
            statusSection
            if !all.isEmpty {
                Section {
                    ForEach(filtered) { ExtensionRow(ext: $0.ext, badge: $0.badge) }
                } header: {
                    Text("\(filtered.count) extensões")
                } footer: {
                    Text("Extensões são programas Kotlin/JVM: o iPhone não as executa. Para usá-las, conecte um "
                         + "servidor de extensões (acima). Sem servidor, use as fontes nativas, como o MangaDex.")
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
                        ForEach(languages(all), id: \.self) { Text(LanguageName.display($0)).tag($0) }
                    }
                } label: { Label("Idioma", systemImage: "character.bubble") }
            }
        }
        .refreshable { await model.refreshRepositories() }
        .task {
            if model.repositoryCatalogs.isEmpty { model.loadCachedRepositories() }
            if model.repositoryCatalogs.contains(where: { $0.snapshot == nil }) { await model.refreshRepositories() }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        let failed = model.repositoryCatalogs.filter { $0.error != nil }
        let cached = model.repositoryCatalogs.compactMap(\.snapshot).filter(\.isFromCache)
        if model.isRefreshingRepositories || !failed.isEmpty || !cached.isEmpty {
            Section {
                if model.isRefreshingRepositories {
                    HStack { ProgressView(); Text("Baixando índices…").foregroundStyle(.secondary) }
                }
                ForEach(failed) { rc in
                    Label("\(rc.repository.name): \(rc.error ?? "")", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange).font(.callout)
                }
                if !cached.isEmpty {
                    Text("Alguns repositórios estão sendo exibidos a partir da cópia local.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func languages(_ list: [Item]) -> [String] {
        Array(Set(list.flatMap(\.ext.languages))).sorted()
    }

    private func filter(_ list: [Item]) -> [Item] {
        list.filter { i in
            let e = i.ext
            return (model.settings.showNSFWExtensions || e.contentWarning != .nsfw)
                && (language.isEmpty || e.languages.contains(language))
                && (search.isEmpty || e.name.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.ext.name.localizedCaseInsensitiveCompare($1.ext.name) == .orderedAscending }
    }
}

/// Atalho para a tela de repositórios, no topo das listas de extensões.
struct RepositoriesLinkSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            NavigationLink {
                ExtensionRepositoriesView()
            } label: {
                LabeledContent {
                    Text("\(model.settings.extensionRepositories.count)").foregroundStyle(.secondary)
                } label: {
                    Label("Repositórios de extensões", systemImage: "shippingbox")
                }
            }
            .accessibilityIdentifier("repositoriesLink")
        }
    }
}

struct ExtensionRow: View {
    let ext: CatalogExtension
    var badge: String = ""

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
                    if !badge.isEmpty { RepoBadge(text: badge) }
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
