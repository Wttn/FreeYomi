import SwiftUI
import FYDomain
import FYCore
import FYData
import FYSources
import FYServices

/// Folha de filtros/ordenação/exibição aberta pelo botão de filtro da Biblioteca.
struct LibraryOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let categories: [MangaCategory]

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Ordenar por") {
                    Picker("Ordenação", selection: $model.settings.librarySort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Exibir") {
                    Picker("Modo de exibição", selection: $model.settings.libraryDisplayMode) {
                        ForEach(LibraryDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    ItemsPerRowStepper()
                    Toggle("Emblema de não lidos", isOn: $model.settings.showUnreadBadge)
                }
            }
            .navigationTitle("Biblioteca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Controle "Itens por linha" com botões − / + (como na captura de Configurações › Biblioteca).
struct ItemsPerRowStepper: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Label("Itens por linha", systemImage: "square.grid.2x2.fill")
            Spacer()
            HStack(spacing: 10) {
                roundButton("minus", label: "Diminuir") { change(-1) }
                    .disabled(model.settings.libraryItemsPerRow <= AppSettings.itemsPerRowRange.lowerBound)
                Text("\(model.settings.libraryItemsPerRow)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 18)
                roundButton("plus", label: "Aumentar") { change(+1) }
                    .disabled(model.settings.libraryItemsPerRow >= AppSettings.itemsPerRowRange.upperBound)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Itens por linha")
        .accessibilityValue("\(model.settings.libraryItemsPerRow)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(+1)
            case .decrement: change(-1)
            @unknown default: break
            }
        }
    }

    private func change(_ delta: Int) {
        var s = model.settings
        s.setItemsPerRow(s.libraryItemsPerRow + delta)
        model.settings = s
        Haptics.tap()
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(FYColor.badgeBackground, in: Circle())
                .foregroundStyle(FYColor.badgeForeground)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
