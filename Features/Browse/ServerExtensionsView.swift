import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Banner que explica como habilitar a instalação de extensões.
struct ConnectServerBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Extensões Android", systemImage: "server.rack").font(.headline)
                Text("Extensões Android (APK) são programas Kotlin/JVM e o iOS não executa esse código. "
                     + "Se você tiver um Suwayomi-Server (gratuito e open source) no seu computador, conecte-o aqui: "
                     + "as extensões rodam nele, e o iPhone só exibe e lê.")
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
                Text("4. Os repositórios que você adicionou no app são enviados ao servidor. Instale as extensões em Explorar › Extensões.")
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
