import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Aba "Extensões": com servidor conectado, instala/atualiza/remove extensões
/// (que rodam no servidor); sem servidor, mostra o catálogo de metadados.
struct ExtensionsTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.serverClient != nil {
            ServerExtensionsView()
        } else {
            ExtensionCatalogView()
        }
    }
}

/// Banner que explica como habilitar a instalação de extensões.
struct ConnectServerBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Instalar extensões e ler online", systemImage: "server.rack").font(.headline)
                Text("As extensões são programas Kotlin/JVM e o iOS não executa esse código. "
                     + "Rode o Suwayomi-Server (gratuito e open source) no seu computador e conecte-o aqui: "
                     + "você instala as extensões pelo app e lê online normalmente.")
                    .font(.callout).foregroundStyle(.secondary)
                if case .failed(let message) = model.serverState {
                    Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                NavigationLink {
                    ExtensionServerSettingsView()
                } label: {
                    Label("Conectar servidor de extensões", systemImage: "link")
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }
}

struct ServerExtensionsView: View {
    @Environment(AppModel.self) private var model

    @State private var extensions: [SuwayomiExtension] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var busy: Set<String> = []
    @State private var search = ""
    @State private var language = "pt-BR"
    @State private var confirmUninstall: SuwayomiExtension?

    private var filtered: [SuwayomiExtension] {
        extensions.filter { e in
            (model.settings.showNSFWExtensions || !e.isNsfw)
                && (language.isEmpty || e.lang == language || e.lang == "all")
                && (search.isEmpty || e.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let list = filtered
        let installed = list.filter(\.installed).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let updates = installed.filter(\.hasUpdate)
        let available = list.filter { !$0.installed }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        List {
            Section {
                serverStatus
            }
            RepositoriesLinkSection()
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "wifi.exclamationmark").foregroundStyle(.orange) }
            }
            if extensions.isEmpty && !isLoading && errorMessage == nil {
                Section {
                    Text("O servidor ainda não tem extensões disponíveis.")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await addDefaultRepository() }
                    } label: { Label("Enviar meus repositórios ao servidor", systemImage: "arrow.up.circle") }
                    NavigationLink {
                        ExtensionRepositoriesView()
                    } label: { Label("Adicionar repositório", systemImage: "plus.circle") }
                }
            }
            if !updates.isEmpty {
                Section("Atualizações (\(updates.count))") { ForEach(updates) { row($0) } }
            }
            if !installed.isEmpty {
                Section("Instaladas (\(installed.count))") { ForEach(installed) { row($0) } }
            }
            if !available.isEmpty {
                Section {
                    ForEach(available) { row($0) }
                } header: {
                    Text("Disponíveis (\(available.count))")
                } footer: {
                    Text("As extensões são baixadas e executadas pelo seu servidor, não pelo iPhone. "
                         + "Instale apenas extensões de repositórios em que você confia.")
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
                        ForEach(Array(Set(extensions.map(\.lang))).sorted(), id: \.self) {
                            Text(LanguageName.display($0)).tag($0)
                        }
                    }
                } label: { Label("Idioma", systemImage: "character.bubble") }
            }
        }
        .overlay { if isLoading && extensions.isEmpty { ProgressView("Consultando o servidor…") } }
        .refreshable { await load() }
        .task { if extensions.isEmpty { await load() } }
        .onChange(of: model.serverRepositories.map(\.indexURL)) { _, _ in Task { await load() } }
        .confirmationDialog("Remover extensão?", isPresented: Binding(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }
        ), titleVisibility: .visible, presenting: confirmUninstall) { ext in
            Button("Remover \(ext.name)", role: .destructive) { Task { await run(ext, .uninstall) } }
        } message: { _ in
            Text("Títulos desta fonte continuam na biblioteca, mas não poderão ser abertos até reinstalar.")
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch model.serverState {
        case .connected(let name, let version, let sources):
            LabeledContent("Servidor", value: "\(name) \(version)")
            LabeledContent("Fontes disponíveis", value: "\(sources)")
        case .connecting:
            HStack { ProgressView(); Text("Conectando…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .notConfigured:
            Text("Sem servidor")
        }
        NavigationLink {
            ExtensionServerSettingsView()
        } label: { Label("Configurar servidor", systemImage: "gearshape") }
    }

    private enum Action { case install, update, uninstall }

    private func row(_ e: SuwayomiExtension) -> some View {
        HStack(spacing: 14) {
            CoverImage(ref: .remote(url: model.serverClient?.absolute(e.iconUrl) ?? e.iconUrl, headers: [:]))
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name)
                    if let badge = model.repositoryBadge(forPackage: e.pkgName) { RepoBadge(text: badge) }
                }
                Text("v\(e.versionName) · \(LanguageName.display(e.lang))\(e.isNsfw ? " · 18+" : "")\(e.obsolete ? " · obsoleta" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy.contains(e.pkgName) {
                ProgressView()
            } else if !e.installed {
                Button("Instalar") { Task { await run(e, .install) } }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if e.hasUpdate {
                Button("Atualizar") { Task { await run(e, .update) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(role: .destructive) { confirmUninstall = e } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remover \(e.name)")
            }
        }
    }

    private func load() async {
        guard let client = model.serverClient else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            extensions = try await client.extensions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ e: SuwayomiExtension, _ action: Action) async {
        guard let client = model.serverClient else { return }
        busy.insert(e.pkgName)
        defer { busy.remove(e.pkgName) }
        do {
            switch action {
            case .install: try await client.install(e.pkgName)
            case .update: try await client.update(e.pkgName)
            case .uninstall: try await client.uninstall(e.pkgName)
            }
            Haptics.success()
            await load()
            await model.connectServer() // atualiza a lista de fontes
        } catch {
            model.report(error)
        }
    }

    private func addDefaultRepository() async {
        guard let client = model.serverClient else { return }
        isLoading = true
        defer { isLoading = false }
        if model.settings.extensionRepositories.isEmpty {
            do {
                try await client.addExtensionStore(indexURL: ExtensionRepository.keiyoushiURL)
            } catch {
                model.report(error)
                return
            }
        }
        await model.syncRepositoriesWithServer()
        if let note = model.repositorySyncNote { model.alertMessage = note }
        await load()
    }
}

/// Configuração do servidor de extensões.
struct ExtensionServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var allowHTTP = true
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.0.10:4567", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Usuário (opcional)", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Senha (opcional)", text: $password)
                Toggle("Permitir HTTP (rede local)", isOn: $allowHTTP)
            } header: {
                FYSectionHeader("Suwayomi-Server")
            } footer: {
                Text("Endereço do computador onde o Suwayomi-Server está rodando (porta padrão 4567). "
                     + "A senha fica no Keychain do iPhone e nunca é incluída em backups. "
                     + "Fora de casa, use HTTPS (por exemplo, por VPN ou proxy reverso) e desative o HTTP.")
            }

            Section {
                Button {
                    Task {
                        saving = true
                        await model.saveServer(address: address, username: username, password: password, allowHTTP: allowHTTP)
                        saving = false
                    }
                } label: {
                    HStack {
                        Text("Salvar e conectar")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || saving)

                switch model.serverState {
                case .connected(let name, let version, let sources):
                    Label("Conectado a \(name) \(version) · \(sources) fontes", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case .connecting:
                    Label("Conectando…", systemImage: "hourglass")
                case .notConfigured:
                    EmptyView()
                }
            }

            if model.serverClient != nil {
                Section {
                    NavigationLink {
                        ExtensionRepositoriesView()
                    } label: {
                        LabeledContent {
                            Text("\(model.serverRepositories.count)").foregroundStyle(.secondary)
                        } label: {
                            Label("Repositórios de extensões", systemImage: "shippingbox")
                        }
                    }
                } footer: {
                    Text("Os repositórios do app e do servidor são mantidos iguais automaticamente.")
                }
                Section {
                    Button("Desconectar e esquecer o servidor", role: .destructive) {
                        Task { await model.disconnectServer() }
                        address = ""; username = ""; password = ""
                    }
                }
            }

            Section("Como instalar o servidor") {
                Text("1. Baixe a versão para Windows em github.com/Suwayomi/Suwayomi-Server/releases (arquivo win64).")
                Text("2. Execute e libere a porta 4567 no firewall do Windows para a rede privada.")
                Text("3. Descubra o IP do computador (comando ipconfig) e digite acima, por exemplo http://192.168.0.10:4567.")
                Text("4. Os seus repositórios (Keiyoushi por padrão) são enviados ao servidor. Instale as extensões em Explorar › Extensões.")
                Text("Guia completo: docs/EXTENSION_SERVER.md no repositório do FreeYomi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .navigationTitle("Servidor de extensões")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = model.settings.extensionServerURL ?? ""
            username = model.settings.extensionServerUsername ?? ""
            password = KeychainStore.get(account: KeychainStore.extensionServerPassword) ?? ""
            allowHTTP = model.settings.extensionServerAllowHTTP
        }
    }
}
