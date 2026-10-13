import SwiftUI
import FYDomain
import FYCore
import FYData
import FYSources
import FYServices

/// Mais — referência: captura "Mais" (lista de seções com ícones).
///
/// Diferença intencional: na referência, "Sincronizar" e "Rastreamento"
/// têm coroa de recurso premium e o topo exibe "Assinatura Premium ativa".
/// No FreeYomi não existe plano pago: nenhuma coroa, e o topo informa que
/// tudo é gratuito.
struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "heart.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(FYColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gratuito e open source").font(.headline)
                            Text("Sem anúncios, sem assinaturas, sem recursos bloqueados.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    link("Geral", "slider.horizontal.3") { GeneralSettingsView() }
                    link("Aparência", "paintpalette.fill") { AppearanceSettingsView() }
                    link("Biblioteca", "books.vertical.fill") { LibrarySettingsView() }
                    link("Leitor", "book.pages.fill") { ReaderSettingsView() }
                    link("Sincronizar", "cloud") {
                        PlannedFeatureView(title: "Sincronizar", icon: "cloud",
                                           text: "Sincronização opcional e sem servidor próprio (ex.: arquivo de backup "
                                               + "em uma pasta do iCloud Drive escolhida por você). Planejado para depois da Fase 5.")
                    }
                    link("Rastreamento", "arrow.triangle.2.circlepath") {
                        PlannedFeatureView(title: "Rastreamento", icon: "arrow.triangle.2.circlepath",
                                           text: "Integração opcional com serviços como AniList e MyAnimeList, "
                                               + "usando login do próprio usuário. Planejado; gratuito como todo o resto.")
                    }
                    link("Extensões", "safari.fill") { ExtensionSettingsView() }
                    link("Backup e Restauração", "clock.arrow.circlepath") {
                        PlannedFeatureView(title: "Backup e Restauração", icon: "clock.arrow.circlepath",
                                           text: "Exportação e importação da biblioteca, categorias, histórico, progresso e "
                                               + "preferências em arquivo local, com validação antes de restaurar (Fase 5). "
                                               + "Credenciais nunca são incluídas sem proteção explícita.")
                    }
                    link("Segurança", "lock.shield.fill") { SecuritySettingsView() }
                    link("Informações de leitura", "chart.line.uptrend.xyaxis") { ReadingStatsView() }
                    link("Transferências", "arrow.down.to.line") { DownloadsView() }
                }

                Section {
                    ShareLink(item: "FreeYomi — leitor de mangás gratuito e open source para iOS.") {
                        Label("Compartilhar", systemImage: "square.and.arrow.up")
                    }
                    link("Ajuda", "questionmark.circle.fill") { HelpView() }
                    link("Sobre", "info.circle") { AboutView() }
                }
            }
            .navigationTitle("Mais")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func link<D: View>(_ title: String, _ icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

/// Página honesta para funcionalidades ainda não implementadas.
struct PlannedFeatureView: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        ContentUnavailableView {
            Label("\(title) — em desenvolvimento", systemImage: icon)
        } description: {
            Text(text)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Geral

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                Button("Restaurar títulos de demonstração") { Task { await model.restoreDemoData() } }
                Button("Remover títulos de demonstração", role: .destructive) { confirmRemove = true }
            } header: {
                FYSectionHeader("Dados de demonstração")
            } footer: {
                Text("Os títulos de demonstração são fictícios, gerados localmente e marcados com \"DEMO\".")
            }
        }
        .navigationTitle("Geral")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remover os títulos de demonstração?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remover", role: .destructive) { model.removeDemoData() }
        } message: {
            Text("O histórico e o progresso desses títulos também serão removidos.")
        }
    }
}

// MARK: - Aparência

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Tema", selection: $model.settings.theme) {
                    ForEach(ThemePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                FYSectionHeader("Tema")
            } footer: {
                Text("No iOS 26 ou superior, barras e controles usam o material Liquid Glass do sistema. "
                     + "Em versões anteriores, materiais translúcidos equivalentes.")
            }
        }
        .navigationTitle("Aparência")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Biblioteca (referência: captura "Configurações › Biblioteca")

struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [MangaCategory] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                NavigationLink {
                    CategoriesEditorView()
                } label: {
                    SettingRow(title: "Editar Categoria", subtitle: "\(categories.count) categoria(s)", icon: "tag.fill")
                }
                Picker(selection: $model.settings.defaultCategoryId) {
                    Text("Sempre perguntar / nenhuma").tag(Int64?.none)
                    ForEach(categories) { Text($0.name).tag(Int64?.some($0.id)) }
                } label: {
                    Label("Categoria padrão", systemImage: "smallcircle.filled.circle")
                }
            } header: { FYSectionHeader("Categorias") }

            Section {
                Picker(selection: $model.settings.libraryDisplayMode) {
                    ForEach(LibraryDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Label("Modo de exibição", systemImage: "square.grid.2x2.fill")
                }
                ItemsPerRowStepper()
                Toggle(isOn: $model.settings.showUnreadBadge) {
                    Label("Emblemas", systemImage: "bookmark.fill")
                }
            } header: { FYSectionHeader("Exibir") }

            Section {
                Toggle(isOn: $model.settings.skipUpdatingCompleted) {
                    SettingRow(title: "Pular atualização de títulos", subtitle: "Com status concluído", icon: "line.3.horizontal.decrease")
                }
                Toggle(isOn: $model.settings.autoRefreshOnOpen) {
                    SettingRow(title: "Atualização automática",
                               subtitle: "Verificar novos capítulos ao visualizar o título.", icon: "arrow.clockwise")
                }
                SettingRow(title: "Atualizações em segundo plano",
                           subtitle: "Planejado para a Fase 4 (BGTaskScheduler).", icon: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } header: { FYSectionHeader("Atualização") }
        }
        .navigationTitle("Biblioteca")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { categories = (try? model.store.categories.all()) ?? [] }
    }
}

struct CategoriesEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [MangaCategory] = []
    @State private var newName = ""
    @State private var renaming: MangaCategory?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Nova categoria", text: $newName)
                        .onSubmit(add)
                    Button("Adicionar", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                ForEach(categories) { c in
                    Text(c.name)
                        .swipeActions {
                            Button("Excluir", role: .destructive) {
                                model.mutate { try model.store.categories.delete(id: c.id) }
                            }
                            Button("Renomear") { renaming = c; renameText = c.name }
                        }
                }
                .onMove { from, to in
                    var ids = categories.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    model.mutate { try model.store.categories.reorder(ids) }
                }
            } footer: {
                if categories.isEmpty { Text("Nenhuma categoria. Categorias organizam a Biblioteca em abas.") }
            }
        }
        .navigationTitle("Categorias")
        .toolbar { EditButton() }
        .task(id: model.dataVersion) { categories = (try? model.store.categories.all()) ?? [] }
        .alert("Renomear categoria", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $renameText)
            Button("Salvar") {
                if let c = renaming { model.mutate { try model.store.categories.rename(id: c.id, to: renameText) } }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func add() {
        let name = newName
        model.mutate { try model.store.categories.create(name: name) }
        newName = ""
    }
}

// MARK: - Leitor

struct ReaderSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Modo padrão", selection: $model.settings.reader.mode) {
                    ForEach(ReadingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Escala", selection: $model.settings.reader.scale) {
                    ForEach(PageScale.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                FYSectionHeader("Leitura")
            } footer: {
                Text("Nesta versão as páginas são exibidas inteiras. Ajuste à largura/altura e zoom por gesto chegam na Fase 2.")
            }
            Section {
                Toggle("Zonas de toque laterais", isOn: $model.settings.reader.tapZonesEnabled)
                Toggle("Inverter zonas de toque", isOn: $model.settings.reader.invertTapZones)
                    .disabled(!model.settings.reader.tapZonesEnabled)
                Toggle("Mostrar número da página", isOn: $model.settings.reader.showPageNumber)
                Toggle("Manter a tela ativa", isOn: $model.settings.reader.keepScreenOn)
            } header: { FYSectionHeader("Controles") }
        }
        .navigationTitle("Leitor")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Extensões

struct ExtensionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draftURL = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("URL do índice", text: $draftURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.footnote.monospaced())
                Button("Salvar URL") {
                    let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: trimmed), url.scheme == "https" {
                        model.settings.catalogURL = trimmed
                    } else {
                        model.alertMessage = "Informe um endereço HTTPS válido."
                    }
                }
                Button("Restaurar padrão (Keiyoushi)") {
                    model.settings.catalogURL = AppSettings().catalogURL
                    draftURL = model.settings.catalogURL
                }
            } header: {
                FYSectionHeader("Repositório de metadados")
            } footer: {
                Text("Aceita index.pb (protobuf, com ou sem gzip) ou repo.json com o campo index_v2. "
                     + "Apenas metadados são baixados; nenhum código é executado.")
            }
            Section {
                Toggle("Mostrar extensões adultas (18+)", isOn: $model.settings.showNSFWExtensions)
            }
        }
        .navigationTitle("Extensões")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draftURL = model.settings.catalogURL }
    }
}

// MARK: - Segurança e privacidade

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.settings.incognitoMode) {
                    SettingRow(title: "Modo anônimo", subtitle: "Não registrar histórico nem progresso.", icon: "eyeglasses")
                }
            } header: { FYSectionHeader("Privacidade") }
            Section {
                SettingRow(title: "Bloqueio com Face ID", subtitle: "Planejado (Fase 5).", icon: "faceid")
                    .foregroundStyle(.secondary)
            } header: { FYSectionHeader("Bloqueio") }
            Section {
                Text("""
                • Sem anúncios, rastreadores ou SDKs de análise.
                • Biblioteca, histórico e preferências ficam apenas neste aparelho.
                • O app só acessa a internet para baixar o catálogo de metadados e o conteúdo das fontes que você usar.
                • Nenhum código de terceiros é baixado ou executado.
                """)
                .font(.callout)
            } header: { FYSectionHeader("Como seus dados são tratados") }
        }
        .navigationTitle("Segurança")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Estatísticas

struct ReadingStatsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats = (titles: 0, chaptersRead: 0, seconds: 0)

    var body: some View {
        Form {
            LabeledContent("Títulos na biblioteca", value: "\(stats.titles)")
            LabeledContent("Capítulos lidos", value: "\(stats.chaptersRead)")
            LabeledContent("Tempo de leitura", value: HistoryRow.duration(stats.seconds))
        }
        .navigationTitle("Informações de leitura")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) {
            let db = model.store.db
            stats.titles = (try? db.query("SELECT COUNT(*) AS n FROM library").first?.int("n")) ?? 0
            stats.chaptersRead = (try? db.query("SELECT COUNT(*) AS n FROM chapters WHERE is_read = 1").first?.int("n")) ?? 0
            stats.seconds = (try? db.query("SELECT IFNULL(SUM(duration_seconds), 0) AS n FROM history").first?.int("n")) ?? 0
        }
    }
}

// MARK: - Ajuda e Sobre

struct HelpView: View {
    var body: some View {
        List {
            Section("Primeiros passos") {
                Text("1. Abra Explorar › Fontes e escolha uma fonte.")
                Text("2. Toque em um título e use \"Adicionar à biblioteca\".")
                Text("3. Toque em um capítulo para ler. O progresso é salvo automaticamente.")
            }
            Section("Leitor") {
                Text("Toque no centro para mostrar ou ocultar os controles; nas laterais para virar a página.")
                Text("No modo direita → esquerda, o lado esquerdo avança, como em um mangá impresso.")
            }
            Section("Por que as extensões aparecem como incompatíveis?") {
                Text("As extensões do catálogo Keiyoushi são apps Android (APK). O iOS não executa esse código, "
                     + "e o FreeYomi não baixa programas de terceiros. Cada fonte precisa de um adaptador nativo.")
            }
        }
        .navigationTitle("Ajuda")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Versão", value: version)
                LabeledContent("Licença", value: "Apache-2.0")
                LabeledContent("Preço", value: "Gratuito, para sempre")
            }
            Section("Créditos e referências") {
                Text("Inspirado no funcionamento do Mihon/Tachiyomi (Apache-2.0) e na experiência do Tachimanga. "
                     + "Nenhum código, marca ou recurso visual desses projetos foi copiado.")
                Text("Metadados de extensões: índice público do Keiyoushi (Apache-2.0).")
            }
            Section("Componentes de terceiros") {
                LabeledContent("SQLite", value: "Domínio público")
                LabeledContent("zlib", value: "Licença zlib")
                Text("Ambos fornecidos pelo próprio iOS. O FreeYomi não usa dependências externas em tempo de execução.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sobre")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Componentes de configurações

/// Cabeçalho de seção em cor de acento (como "Categorias", "Exibir" na captura).
struct FYSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(FYColor.sectionHeader)
            .textCase(nil)
    }
}

/// Linha com título, subtítulo e ícone (padrão da tela de configurações de referência).
struct SettingRow: View {
    let title: String
    let subtitle: String?
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}
