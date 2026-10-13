import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

@main
struct FreeYomiApp: App {
    @State private var model = AppModel.makeForLaunch()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
                .tint(FYColor.accent)
                .task { await model.bootstrap() }
                .onOpenURL { model.handleOpenURL($0) }
        }
    }
}
