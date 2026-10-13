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

    /// Fase 3: MangaDex listado como fonte nativa e caminho para instalar extensões via servidor.
    func testOnlineSourcesAndExtensionServerEntryPoints() {
        app.tabBars.buttons["Explorar"].tap()
        XCTAssertTrue(app.staticTexts["MangaDex"].waitForExistence(timeout: 5))
        app.buttons["Extensões"].tap()
        XCTAssertTrue(app.buttons["Conectar servidor de extensões"].waitForExistence(timeout: 10))
        app.buttons["Conectar servidor de extensões"].tap()
        XCTAssertTrue(app.textFields["http://192.168.0.10:4567"].waitForExistence(timeout: 5))
    }

    /// Tela "Repositórios de extensões": repositório padrão listado, adicionar
    /// recusa endereço sem HTTPS (não depende de rede).
    func testExtensionRepositoriesScreen() {
        app.tabBars.buttons["Explorar"].tap()
        app.buttons["Extensões"].tap()
        let link = app.buttons["repositoriesLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.navigationBars["Repositórios de extensões"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copiar"].firstMatch.exists)

        app.buttons["addRepositoryButton"].tap()
        let field = app.textFields["repositoryURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("http://exemplo.com/index.pb")
        app.buttons["Verificar"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'recusados por segurança'")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'FelipeGFA'")).firstMatch.exists,
                      "sugestões em \"Encontrar repositório\"")
        app.buttons["Cancelar"].tap()
    }
}
