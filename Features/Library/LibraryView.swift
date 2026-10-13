import SwiftUI
import UniformTypeIdentifiers
import FYDomain
import FYCore
import FYData
import FYSources
import FYServices

/// Biblioteca — referência: captura "Biblioteca" (grade de 2 colunas,
/// capas grandes com título sobreposto e emblema de não lidos).
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    @State private var items: [LibraryTitle] = []
    @State private var categories: [MangaCategory] = []
    @State private var selectedCategory: Int64? = nil
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showOptions = false
    @State private var isSelecting = false
    @State private var selection = Set<Int64>()
    @State private var loadError: String?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Biblioteca")
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar { toolbarContent }
                .searchable(text: $searchText, isPresented: $isSearching, prompt: "Pesquisar na biblioteca")
                .task(id: reloadKey) { reload() }
                .refreshable { await model.refreshLibrary() }
                .sheet(isPresented: $showOptions) { LibraryOptionsSheet(categories: categories) }
                .navigationDestination(for: Int64.self) { MangaDetailView(mangaId: $0) }
                .safeAreaInset(edge: .bottom) { if isSelecting { selectionBar } }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes,
                              allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): Task { await model.importFiles(urls) }
                    case .failure(let error): model.report(error)
                    }
                }
        }
    }

    /// CBZ, ZIP, EPUB e pastas.
    static let importTypes: [UTType] = {
        var types: [UTType] = [.zip, .epub, .folder]
        if let cbz = UTType(filenameExtension: "cbz") { types.insert(cbz, at: 0) }
        return types
    }()

    private var reloadKey: String {
        "\(model.dataVersion)|\(searchText)|\(selectedCategory ?? -1)|\(model.settings.librarySort.rawValue)"
    }

    private func reload() {
        do {
            categories = try model.store.categories.all()
            if let c = selectedCategory, !categories.contains(where: { $0.id == c }) { selectedCategory = nil }
            items = try model.store.library.items(categoryId: selectedCategory, search: searchText,
                                                  sort: model.settings.librarySort)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            EmptyStateView(title: "Erro ao carregar", systemImage: "exclamationmark.triangle", message: loadError)
        } else {
            ScrollView {
                if !categories.isEmpty { categoryChips }
                if items.isEmpty {
                    emptyState.padding(.top, 80)
                } else {
                    switch model.settings.libraryDisplayMode {
                    case .grid, .comfortableGrid: grid
                    case .list: list
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            VStack(spacing: 16) {
                EmptyStateView(title: "Biblioteca vazia", systemImage: "books.vertical",
                               message: "Importe arquivos CBZ, ZIP, EPUB ou pastas de imagens, ou adicione títulos pela aba Explorar. Tudo fica salvo apenas neste aparelho.")
                Button { showImporter = true } label: { Label("Importar arquivos", systemImage: "plus") }
                    .fyProminentButton()
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Todas", id: nil)
                ForEach(categories) { chip($0.name, id: $0.id) }
            }
            .padding(.horizontal, FYMetrics.screenPadding)
        }
        .padding(.bottom, 4)
    }

    private func chip(_ name: String, id: Int64?) -> some View {
        let active = selectedCategory == id
        return Button(name) { selectedCategory = id }
            .font(.subheadline.weight(active ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(active ? FYColor.badgeForeground : .primary)
            .background(active ? AnyShapeStyle(FYColor.badgeBackground) : AnyShapeStyle(.quaternary), in: Capsule())
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: FYMetrics.gridSpacing),
              count: max(1, model.settings.libraryItemsPerRow))
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: FYMetrics.gridSpacing) {
            ForEach(items) { item in
                cell(item) {
                    LibraryGridCell(item: item, overlayTitle: model.settings.libraryDisplayMode == .grid,
                                    showBadge: model.settings.showUnreadBadge,
                                    compact: model.settings.libraryItemsPerRow >= 4)
                }
            }
        }
        .padding(.horizontal, FYMetrics.screenPadding)
        .padding(.bottom, 16)
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                cell(item) { LibraryListRow(item: item, showBadge: model.settings.showUnreadBadge) }
                Divider().padding(.leading, 84)
            }
        }
    }

    /// Envolve a célula com navegação, seleção múltipla e menu contextual.
    @ViewBuilder
    private func cell<Content: View>(_ item: LibraryTitle, @ViewBuilder _ label: () -> Content) -> some View {
        let selected = selection.contains(item.id)
        if isSelecting {
            Button {
                if selected { selection.remove(item.id) } else { selection.insert(item.id) }
                Haptics.tap()
            } label: {
                label()
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selected ? FYColor.accent : .white)
                            .shadow(radius: 2)
                            .padding(8)
                    }
                    .opacity(selected ? 1 : 0.75)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(value: item.manga.id) { label() }
                .buttonStyle(.plain)
                .contextMenu { itemMenu(for: item) }
        }
    }

    @ViewBuilder
    private func itemMenu(for item: LibraryTitle) -> some View {
        Button {
            markAllRead([item.id])
        } label: { Label("Marcar tudo como lido", systemImage: "checkmark.circle") }
        Button {
            isSelecting = true
            selection = [item.id]
        } label: { Label("Selecionar", systemImage: "checkmark.circle.badge.plus") }
        Button(role: .destructive) {
            model.mutate { try model.store.library.remove(mangaIds: [item.id]) }
        } label: { Label("Remover da biblioteca", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Tudo") { selection = Set(items.map(\.id)) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("OK") { isSelecting = false; selection = [] }.bold()
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Label("Importar arquivos", systemImage: "plus")
                }
                .disabled(model.isImporting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showOptions = true } label: {
                    Label("Filtros e exibição", systemImage: "line.3.horizontal.decrease")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { isSearching = true } label: { Label("Pesquisar", systemImage: "magnifyingglass") }
                Menu {
                    Button { isSelecting = true } label: { Label("Selecionar títulos", systemImage: "checkmark.circle") }
                    Button {
                        Task { await model.refreshLibrary() }
                    } label: { Label("Atualizar biblioteca", systemImage: "arrow.clockwise") }
                } label: {
                    Label("Mais opções", systemImage: "ellipsis")
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selecionado(s)").font(.subheadline.weight(.medium))
            Spacer()
            Button { markAllRead(Array(selection)) } label: {
                Label("Marcar como lido", systemImage: "checkmark.circle")
            }
            .disabled(selection.isEmpty)
            Button(role: .destructive) {
                let ids = Array(selection)
                model.mutate { try model.store.library.remove(mangaIds: ids) }
                selection = []
                isSelecting = false
            } label: { Label("Remover", systemImage: "trash") }
            .disabled(selection.isEmpty)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .fyGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func markAllRead(_ mangaIds: [Int64]) {
        model.mutate {
            for id in mangaIds {
                let chapters = try model.store.chapters.chapters(mangaId: id)
                try model.store.chapters.setRead(chapters.map(\.id), read: true)
            }
        }
        Haptics.success()
    }
}

// MARK: - Células

struct LibraryGridCell: View {
    let item: LibraryTitle
    let overlayTitle: Bool
    let showBadge: Bool
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1 / FYMetrics.coverAspect, contentMode: .fit)
                .overlay { CoverView(manga: item.manga) }
                .clipShape(RoundedRectangle(cornerRadius: FYMetrics.coverCornerRadius, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if overlayTitle {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                            Text(item.manga.title)
                                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .padding(10)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: FYMetrics.coverCornerRadius, style: .continuous))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showBadge && item.unreadCount > 0 {
                        UnreadBadge(count: item.unreadCount).padding(8)
                    }
                }
            if !overlayTitle {
                Text(item.manga.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [item.manga.title]
        if item.unreadCount > 0 { parts.append("\(item.unreadCount) não lidos") }
        if let last = item.lastReadChapterName { parts.append("último lido: \(last)") }
        return parts.joined(separator: ", ")
    }
}

struct LibraryListRow: View {
    let item: LibraryTitle
    let showBadge: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverView(manga: item.manga, cornerRadius: FYMetrics.thumbnailCornerRadius)
                .frame(width: 56, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.manga.title).font(.headline).lineLimit(2)
                if let last = item.lastReadChapterName {
                    Text("Último lido: \(last)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let date = item.lastReadAt {
                    Label(date.formatted(.relative(presentation: .named)), systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showBadge && item.unreadCount > 0 { UnreadBadge(count: item.unreadCount) }
        }
        .padding(.horizontal, FYMetrics.screenPadding)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
