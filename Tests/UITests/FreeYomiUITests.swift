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
}
