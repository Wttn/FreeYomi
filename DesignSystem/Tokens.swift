import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Tokens visuais do FreeYomi.
///
/// Derivados da análise das capturas de referência (ver
/// docs/SCREEN_REFERENCE_MAPPING.md): fundo quase preto no tema escuro,
/// acento azul-lavanda suave para seleção e emblemas, cantos arredondados
/// generosos nas capas. Cores semânticas do sistema são usadas sempre que
/// possível para que o tema claro e o alto contraste funcionem sem ajustes.
enum FYColor {
    /// Acento azul-lavanda (seleção da tab bar, emblemas, controles ativos).
    static let accent = Color(light: Color(red: 0.25, green: 0.38, blue: 0.80),
                              dark: Color(red: 0.66, green: 0.76, blue: 0.98))
    /// Fundo do emblema de não lidos (pílula clara com texto escuro).
    static let badgeBackground = Color(light: Color(red: 0.80, green: 0.85, blue: 0.98),
                                       dark: Color(red: 0.75, green: 0.82, blue: 0.97))
    static let badgeForeground = Color(red: 0.07, green: 0.11, blue: 0.24)
    /// Cabeçalhos de seção nas configurações ("Categorias", "Exibir"…).
    static let sectionHeader = accent
    /// Fundo de placeholders de capa.
    static let placeholder = Color(uiColor: .secondarySystemFill)
    static let secondaryText = Color.secondary
}

enum FYMetrics {
    static let coverCornerRadius: CGFloat = 12
    static let thumbnailCornerRadius: CGFloat = 10
    static let gridSpacing: CGFloat = 8
    static let screenPadding: CGFloat = 12
    /// Proporção altura/largura das capas na grade (≈ 0,75 nas capturas).
    static let coverAspect: CGFloat = 3.0 / 2.25
    static let historyThumbSize = CGSize(width: 56, height: 80)
}

extension Color {
    /// Cor dinâmica para claro/escuro.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Feedback tátil discreto para ações relevantes.
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
