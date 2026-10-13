import SwiftUI
import FYDomain
import FYCore
import FYData
import FYSources
import FYServices

/// Transferências. A tabela e o repositório de downloads já existem (com
/// prevenção de duplicatas); o gerenciador de downloads em segundo plano e a
/// leitura offline chegam na Fase 4.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var tasks: [DownloadTask] = []

    var body: some View {
        Group {
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma transferência", systemImage: "arrow.down.circle")
                } description: {
                    Text("Downloads de capítulos para leitura offline serão implementados na Fase 4.")
                }
            } else {
                List(tasks) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Capítulo #\(t.chapterId)")
                        ProgressView(value: t.progress)
                        Text("\(t.state.rawValue) · \(ByteCountFormatter.string(fromByteCount: t.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Transferências")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { tasks = (try? model.store.downloads.all()) ?? [] }
    }
}
