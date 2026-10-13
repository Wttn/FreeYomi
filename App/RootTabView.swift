import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Navegação principal com cinco abas, na mesma ordem das capturas de
/// referência: Biblioteca, Atualizações, Explorar, Histórico, Mais.
///
/// Compilado com o SDK do iOS 26, o `TabView` nativo recebe automaticamente
/// a tab bar flutuante em Liquid Glass; em versões anteriores, a tab bar
/// translúcida padrão do sistema.
struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppTab = .library

    enum AppTab: Hashable { case library, updates, browse, history, more }

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tabItem { Label("Biblioteca", systemImage: "books.vertical.fill") }
                .tag(AppTab.library)

            UpdatesView()
                .tabItem { Label("Atualizações", systemImage: "bolt.fill") }
                .tag(AppTab.updates)
                .badge(model.lastRefresh?.newChapters.count ?? 0)

            BrowseView()
                .tabItem { Label("Explorar", systemImage: "safari") }
                .tag(AppTab.browse)

            HistoryView()
                .tabItem { Label("Histórico", systemImage: "clock.fill") }
                .tag(AppTab.history)

            MoreView()
                .tabItem { Label("Mais", systemImage: "gearshape.fill") }
                .tag(AppTab.more)
        }
        .fyTabBarMinimizeOnScroll()
        .alert("Aviso", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}
