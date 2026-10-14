import XCTest

/// Fluxos principais em banco em memória (`-ui-testing`), sem internet.
final class FreeYomiUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    /// Critério 1: abre sem depender de internet e mostra as cinco abas.
    func testLaunchShowsAllTabs() {
        for tab in ["Biblioteca", "Atualizações", "Explorar", "Histórico", "Mais"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 10), "aba \(tab) ausente")
        }
    }

    /// Dados de demonstração identificados aparecem na Biblioteca.
    func testDemoTitlesAppearInLibrary() {
        let demo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demonstração'")).firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
    }

    /// Critério 4/6: abrir um título, abrir um capítulo e navegar entre páginas.
    func testOpenChapterAndTurnPage() {
        let demo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demonstração · O Farol'")).firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Continuar' OR label == 'Começar'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let close = app.buttons["Fechar leitor"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        app.swipeRight()
        close.tap()
    }

    /// A tela "Mais" não exibe nenhum paywall.
    func testMoreScreenHasNoPaywall() {
        app.tabBars.buttons["Mais"].tap()
        XCTAssertTrue(app.staticTexts["Gratuito e open source"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Assinatura Premium ativa"].exists)
    }

    /// Explorar lista a fonte demo como implementada.
    func testBrowseListsDemoSource() {
        app.tabBars.buttons["Explorar"].tap()
        XCTAssertTrue(app.staticTexts["Demonstração (local)"].waitForExistence(timeout: 5))
    }

    /// Nenhuma fonte online nem repositório vem de fábrica; a aba Extensões
    /// mostra o estado vazio e o caminho para adicionar um repositório.
    func testNoPreconfiguredSourcesOrRepositories() {
        app.tabBars.buttons["Explorar"].tap()
        XCTAssertTrue(app.staticTexts["Demonstração (local)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["MangaDex"].exists, "nenhuma fonte online pré-instalada")
        app.buttons["Extensões"].tap()
        XCTAssertTrue(app.staticTexts["Nenhuma extensão"].waitForExistence(timeout: 10))
        let link = app.buttons["repositoriesLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Repositórios de extensões"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'ainda não adicionou nenhum repositório'"))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'github.com'")).firstMatch.exists,
                       "nenhum endereço sugerido")
    }

    /// Adicionar repositório: recusa HTTP sem a opção explícita, sem rede, e não mostra sugestões.
    func testAddRepositoryValidatesURL() {
        app.tabBars.buttons["Explorar"].tap()
        app.buttons["Extensões"].tap()
        let link = app.buttons["repositoriesLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        app.buttons["addRepositoryButton"].tap()
        let field = app.textFields["repositoryURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirmAddRepository"].isEnabled, "Adicionar só depois de validar")
        field.tap()
        field.typeText("http://exemplo.com/index.min.json")
        app.buttons["validateRepository"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'recusados por segurança'")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirmAddRepository"].isEnabled)
        app.buttons["Cancelar"].tap()
        XCTAssertTrue(app.navigationBars["Repositórios de extensões"].waitForExistence(timeout: 5))
    }

    /// Mais › Extensões: seção "Repositórios de extensões" e caminho para o servidor de extensões.
    func testExtensionSettingsEntryPoints() {
        app.tabBars.buttons["Mais"].tap()
        let extensions = app.buttons["Extensões"].firstMatch
        XCTAssertTrue(extensions.waitForExistence(timeout: 5))
        extensions.tap()
        XCTAssertTrue(app.staticTexts["Repositórios de extensões"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsRepositoriesLink"].exists)
        let server = app.buttons["extensionServerLink"]
        if !server.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        XCTAssertTrue(app.textFields["http://192.168.0.10:4567"].waitForExistence(timeout: 5))
    }
}
