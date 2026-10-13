import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

// Camada de compatibilidade do Liquid Glass.
//
// - Compilado com Swift 6.2+ (Xcode 26) e executando no iOS 26+: usa as APIs
//   nativas `glassEffect`, `.buttonStyle(.glass)` e `tabBarMinimizeBehavior`.
// - Em iOS 17/18 (ou Xcode antigo): materiais translúcidos do sistema
//   (`.ultraThinMaterial`, `.borderedProminent`), visualmente coerentes.
//
// Regra do design system: vidro apenas em controles flutuantes e barras.
// Nunca sobre as páginas do mangá nem atrás de blocos longos de texto.

extension View {
    /// Fundo de vidro em controles flutuantes (botões, pílulas, barras do leitor).
    @ViewBuilder
    func fyGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// Botão de ação principal (ex.: "Adicionar à biblioteca").
    @ViewBuilder
    func fyProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    /// Botão secundário em vidro.
    @ViewBuilder
    func fySecondaryButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    /// No iOS 26 a tab bar encolhe ao rolar para baixo, liberando espaço para o conteúdo.
    @ViewBuilder
    func fyTabBarMinimizeOnScroll() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Pílula de vidro com ícones, usada nas barras do leitor.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fyGlass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}
