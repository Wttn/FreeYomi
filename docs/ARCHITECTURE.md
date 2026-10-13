# Arquitetura

```
┌──────────────────────────── App iOS (SwiftUI, só macOS/Xcode) ─────────────────────────────┐
│ App/            FreeYomiApp → RootTabView (5 abas) ; AppModel (@Observable, @MainActor)    │
│ Features/       Library · Browse · Reader · Updates · History · Downloads · Settings · Manga│
│ DesignSystem/   Tokens · Glass (Liquid Glass + fallback) · Covers/Pages · componentes      │
└───────────────────────────────────────┬───────────────────────────────────────────────────┘
                                        │ importa
┌──────────────────────── Packages/FreeYomiKit (Swift puro: iOS, macOS, Linux) ──────────────┐
│ FYServices   LibraryService: adicionar à biblioteca, atualizar capítulos, dados demo       │
│ FYSources    MangaSource (protocolo) · DemoSource · LocalSource · LocalImporter ·        │
│              LocalLibraryStore · ComicInfo/EPUB · SourceRegistry · ExtensionCatalog       │
│ FYData       SQLiteDatabase · Migrator · DataStore · repositórios                         │
│ FYDomain     Manga · Chapter · Page · Source · LibraryEntry · MangaCategory ·             │
│              ReadingProgress · ReadingHistoryEntry · DownloadTask · AppSettings ·         │
│              ReaderNavigation (regras de toque/pré-carga)                                  │
│ FYCore       FYError · Gzip/RawInflate/CRC32 (zlib) · ZipArchive/ZipWriter · DiskCache · │
│              NaturalOrder · ImageFormat · ProtobufReader/Writer · HTTPClient · Redactor · │
│              URLPolicy · PathSanitizer                                                     │
│ CSQLite, CZlib  módulos de sistema                                                         │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

Dependências entre módulos: `FYCore ← FYDomain ← {FYData, FYSources} ← FYServices ← App`. A interface nunca fala diretamente com o SQLite: usa os repositórios expostos por `DataStore`.

## Fluxo de dados

1. **Inicialização:** `AppModel.makeForLaunch()` abre `Application Support/FreeYomi/library.sqlite` (ou um banco em memória com `-ui-testing`), aplica as migrações e carrega `AppSettings`. Em `bootstrap()` registra as fontes nativas e insere os dados demo na primeira execução. Nada disso depende de rede (critério 1).
2. **Leitura:** a tela recarrega via `.task(id: model.dataVersion)`; cada mutação passa por `model.mutate { … }`, que grava, incrementa `dataVersion` e mostra erros em alerta.
3. **Fonte → biblioteca:** `LibraryService.fetchAndStore` chama `details` + `chapters` da fonte, grava o título pela chave `(source_id, key)` e sincroniza os capítulos por `(manga_id, key)`, preservando lido/marcador.
4. **Leitor:** `MangaSource.pages` → `[Page]` com `ImageRef` (`remote`, `file` ou `demo`). O progresso é salvo a cada troca de página (`ReadingProgress`: página, total, deslocamento, concluído) e o tempo de leitura é acumulado no histórico ao sair ou trocar de capítulo. Ao abrir, o leitor retoma a página salva; ao chegar à última página, marca o capítulo como lido.
5. **Importação local:** `fileImporter`/"Abrir com" → `AppModel.importFiles` (acesso security-scoped) → `LibraryService.importLocal` → `LocalImporter` (valida, extrai e renumera em `LocalFiles/<uuid>/c0001/0001.jpg`, grava `manifest.json`) → `LocalSource` expõe o título como qualquer fonte → adicionado à biblioteca.
6. **Imagens:** `ImagePipeline` (app) resolve `ImageRef.file` contra `LocalFiles`, `.remote` com cache em disco, decodifica reduzido com ImageIO e mantém um `NSCache` limitado.
7. **Catálogo:** `ExtensionCatalogClient.refresh` → valida HTTPS → GET → gzip? → `{` (repo.json → segue `index_v2`) / `[` (legado, recusado) / protobuf → decodifica → salva em cache. Sem rede, usa o cache e informa o erro.

## Esquema do banco (v1)

| Tabela | Chave | Observações |
|---|---|---|
| `sources` | `id` (texto estável) | fixada, último uso |
| `manga` | `id` autoincremento, `UNIQUE(source_id, key)` | `is_demo` marca dados fictícios |
| `chapters` | `id`, `UNIQUE(manga_id, key)` | `source_order` (0 = mais recente), lido, marcador |
| `library` | `manga_id` | data de adição |
| `categories`, `manga_categories` | — | ordem, N:N |
| `reading_progress` | `chapter_id` | página, total, `scroll_offset` 0–1, concluído |
| `history` | `id`, `UNIQUE(chapter_id)` | data, duração acumulada |
| `downloads` | `id`, `UNIQUE(chapter_id)` | estado, páginas, bytes, erro |
| `settings` | `key` | `AppSettings` em JSON |

Todas as chaves estrangeiras usam `ON DELETE CASCADE`: remover os dados demo apaga também os capítulos, o progresso e o histórico deles.

## Testes

| Nível | Onde | Roda em |
|---|---|---|
| Unidade/integração do núcleo (57 casos) | `Packages/FreeYomiKit/Tests` | Linux, Windows (Docker), macOS |
| Teste ao vivo do índice | `CatalogClientTests.testLiveKeiyoushiIndex` (`FY_LIVE_TESTS=1`) | CI, não bloqueante |
| Interface (5 fluxos da Fase 1 + 3 da Fase 2, incluindo métrica de memória) | `Tests/UITests` | Simulador iOS no CI |
