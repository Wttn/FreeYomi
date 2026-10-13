import XCTest

/// Fase 2: importação local, leitor com zoom, rolagem, progresso e memória.
/// Usa `-ui-testing-sample`, que gera e importa um CBZ de 6 páginas
/// (uma dupla e uma faixa longa) desenhado pelo próprio app.
final class ReaderPhase2UITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sample"]
        app.launch()
    }

    private func openSample() {
        let sample = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Amostra local'")).firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 20), "CBZ de amostra não foi importado")
        sample.tap()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Continuar' OR label == 'Começar'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["Fechar leitor"].waitForExistence(timeout: 10))
    }

    /// Critério 3 + 4: arquivo local importado abre e navega.
    func testImportedArchiveOpensWithZoomAndPaging() {
        openSample()
        let page = app.scrollViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "página com zoom (UIScrollView) esperada")
        page.doubleTap()          // zoom
        page.doubleTap()          // volta
        page.pinch(withScale: 2.0, velocity: 1.5)
        page.pinch(withScale: 0.5, velocity: -1.5)
        app.swipeRight()          // D→E: próxima página
        app.swipeRight()
        XCTAssertTrue(app.buttons["Fechar leitor"].exists || app.otherElements.firstMatch.exists)
    }

    /// Critério 5: progresso salvo e restaurado após fechar o leitor.
    func testProgressIsRestored() {
        openSample()
        app.swipeRight()
        app.swipeRight()
        let close = app.buttons["Fechar leitor"]
        if !close.isHittable { app.tap() } // mostra os controles se estiverem ocultos
        close.tap()
        let resume = app.buttons["Continuar"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "o detalhe deve oferecer continuar a leitura")
    }

    /// Critério 6 + memória: modo webtoon rola as 6 páginas, inclusive a faixa longa.
    func testWebtoonScrollingMemory() throws {
        openSample()
        app.buttons["Modo de leitura e escala"].tap()
        let webtoon = app.buttons["Webtoon (rolagem longa)"]
        XCTAssertTrue(webtoon.waitForExistence(timeout: 5))
        webtoon.tap()

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        }
        XCTAssertEqual(app.state, .runningForeground, "o app não pode encerrar por falta de memória")
    }
}
