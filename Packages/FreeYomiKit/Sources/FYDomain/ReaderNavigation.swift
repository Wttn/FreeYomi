import Foundation

/// Regras de navegação do leitor, independentes da interface (testáveis).
public enum TapZone: Equatable, Sendable {
    case previous, next, menu
}

public enum ReaderNavigation {
    /// Decide a ação para um toque na posição horizontal relativa `x` (0…1).
    /// Terço esquerdo / central / direito. Em modo direita→esquerda, o lado
    /// esquerdo avança (como em um mangá impresso).
    public static func zone(forRelativeX x: Double, mode: ReadingMode, invert: Bool) -> TapZone {
        let region: Int = x < 1.0 / 3.0 ? 0 : (x > 2.0 / 3.0 ? 2 : 1)
        if region == 1 { return .menu }
        var leftIsNext = (mode == .pagedRightToLeft)
        if invert { leftIsNext.toggle() }
        if region == 0 { return leftIsNext ? .next : .previous }
        return leftIsNext ? .previous : .next
    }

    /// Índice resultante após a ação, limitado ao capítulo. Retorna `nil` quando
    /// a ação ultrapassa o início/fim (o leitor deve oferecer o capítulo vizinho).
    public static func target(from index: Int, zone: TapZone, pageCount: Int) -> Int? {
        switch zone {
        case .menu: return index
        case .next: return index + 1 < pageCount ? index + 1 : nil
        case .previous: return index - 1 >= 0 ? index - 1 : nil
        }
    }

    /// Páginas a pré-carregar a partir da página atual.
    public static func preloadIndices(current: Int, count: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0, count > 0 else { return [] }
        let start = current + 1
        let end = min(pageCount - 1, current + count)
        guard start <= end else { return [] }
        return Array(start...end)
    }
}
