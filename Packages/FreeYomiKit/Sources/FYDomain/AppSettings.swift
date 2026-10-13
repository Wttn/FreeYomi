import Foundation

public enum ThemePreference: String, Codable, Sendable, CaseIterable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return "Automático"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }
}

public enum LibraryDisplayMode: String, Codable, Sendable, CaseIterable {
    /// Capa com título sobreposto (como na captura de referência).
    case grid
    /// Capa com título abaixo.
    case comfortableGrid
    case list

    public var label: String {
        switch self {
        case .grid: return "Grade"
        case .comfortableGrid: return "Grade confortável"
        case .list: return "Lista"
        }
    }
}

public enum LibrarySort: String, Codable, Sendable, CaseIterable {
    case alphabetical, lastRead, dateAdded, unreadCount

    public var label: String {
        switch self {
        case .alphabetical: return "Alfabética"
        case .lastRead: return "Última leitura"
        case .dateAdded: return "Data de adição"
        case .unreadCount: return "Não lidos"
        }
    }
}

public enum ReadingMode: String, Codable, Sendable, CaseIterable {
    case pagedRightToLeft
    case pagedLeftToRight
    case pagedVertical
    case continuousVertical
    case webtoon

    public var label: String {
        switch self {
        case .pagedRightToLeft: return "Paginado (direita → esquerda)"
        case .pagedLeftToRight: return "Paginado (esquerda → direita)"
        case .pagedVertical: return "Paginado vertical"
        case .continuousVertical: return "Vertical contínuo"
        case .webtoon: return "Webtoon (rolagem longa)"
        }
    }

    public var isPaged: Bool {
        switch self {
        case .pagedRightToLeft, .pagedLeftToRight, .pagedVertical: return true
        case .continuousVertical, .webtoon: return false
        }
    }
}

public enum PageScale: String, Codable, Sendable, CaseIterable {
    case fitScreen, fitWidth, fitHeight, original

    public var label: String {
        switch self {
        case .fitScreen: return "Página inteira"
        case .fitWidth: return "Ajustar à largura"
        case .fitHeight: return "Ajustar à altura"
        case .original: return "Tamanho original"
        }
    }
}

public enum UnreadBadgeStyle: String, Codable, Sendable, CaseIterable {
    case unread, none
}

public struct ReaderSettings: Codable, Sendable, Hashable {
    public var mode: ReadingMode = .pagedRightToLeft
    public var scale: PageScale = .fitScreen
    public var tapZonesEnabled: Bool = true
    public var invertTapZones: Bool = false
    public var keepScreenOn: Bool = true
    public var showPageNumber: Bool = true
    public var preloadPageCount: Int = 4
    public var useCustomBrightness: Bool = false
    public var customBrightness: Double = 0.5

    public init() {}
}

/// Preferências globais, salvas localmente em JSON. Campos novos devem ter
/// valor padrão para que versões antigas continuem decodificando.
public struct AppSettings: Codable, Sendable, Hashable {
    public var schemaVersion: Int = 1
    public var theme: ThemePreference = .system
    public var libraryDisplayMode: LibraryDisplayMode = .grid
    public var libraryItemsPerRow: Int = 2
    public var librarySort: LibrarySort = .alphabetical
    public var showUnreadBadge: Bool = true
    public var defaultCategoryId: Int64? = nil
    public var skipUpdatingCompleted: Bool = true
    public var autoRefreshOnOpen: Bool = false
    public var reader: ReaderSettings = ReaderSettings()
    public var demoDataSeeded: Bool = false
    public var showNSFWExtensions: Bool = false
    /// Modo anônimo: não registra histórico nem progresso.
    public var incognitoMode: Bool = false
    public var catalogURL: String = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"

    public init() {}

    public static let itemsPerRowRange = 1...6

    public mutating func setItemsPerRow(_ value: Int) {
        libraryItemsPerRow = min(max(value, Self.itemsPerRowRange.lowerBound), Self.itemsPerRowRange.upperBound)
    }

    // Decodificação tolerante: campos ausentes recebem o valor padrão.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        theme = (try? c.decodeIfPresent(ThemePreference.self, forKey: .theme)) ?? d.theme
        libraryDisplayMode = (try? c.decodeIfPresent(LibraryDisplayMode.self, forKey: .libraryDisplayMode)) ?? d.libraryDisplayMode
        libraryItemsPerRow = try c.decodeIfPresent(Int.self, forKey: .libraryItemsPerRow) ?? d.libraryItemsPerRow
        librarySort = (try? c.decodeIfPresent(LibrarySort.self, forKey: .librarySort)) ?? d.librarySort
        showUnreadBadge = try c.decodeIfPresent(Bool.self, forKey: .showUnreadBadge) ?? d.showUnreadBadge
        defaultCategoryId = try c.decodeIfPresent(Int64.self, forKey: .defaultCategoryId)
        skipUpdatingCompleted = try c.decodeIfPresent(Bool.self, forKey: .skipUpdatingCompleted) ?? d.skipUpdatingCompleted
        autoRefreshOnOpen = try c.decodeIfPresent(Bool.self, forKey: .autoRefreshOnOpen) ?? d.autoRefreshOnOpen
        reader = (try? c.decodeIfPresent(ReaderSettings.self, forKey: .reader)) ?? d.reader
        demoDataSeeded = try c.decodeIfPresent(Bool.self, forKey: .demoDataSeeded) ?? d.demoDataSeeded
        showNSFWExtensions = try c.decodeIfPresent(Bool.self, forKey: .showNSFWExtensions) ?? d.showNSFWExtensions
        incognitoMode = try c.decodeIfPresent(Bool.self, forKey: .incognitoMode) ?? d.incognitoMode
        catalogURL = try c.decodeIfPresent(String.self, forKey: .catalogURL) ?? d.catalogURL
        setItemsPerRow(libraryItemsPerRow)
    }
}

extension ReaderSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings()
        mode = (try? c.decodeIfPresent(ReadingMode.self, forKey: .mode)) ?? d.mode
        scale = (try? c.decodeIfPresent(PageScale.self, forKey: .scale)) ?? d.scale
        tapZonesEnabled = try c.decodeIfPresent(Bool.self, forKey: .tapZonesEnabled) ?? d.tapZonesEnabled
        invertTapZones = try c.decodeIfPresent(Bool.self, forKey: .invertTapZones) ?? d.invertTapZones
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? d.keepScreenOn
        showPageNumber = try c.decodeIfPresent(Bool.self, forKey: .showPageNumber) ?? d.showPageNumber
        preloadPageCount = try c.decodeIfPresent(Int.self, forKey: .preloadPageCount) ?? d.preloadPageCount
        useCustomBrightness = try c.decodeIfPresent(Bool.self, forKey: .useCustomBrightness) ?? d.useCustomBrightness
        customBrightness = try c.decodeIfPresent(Double.self, forKey: .customBrightness) ?? d.customBrightness
    }
}
