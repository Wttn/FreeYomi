# Relatório da Fase 3 — Extensões e leitura online

Data: 13/10/2026 · Versão: 0.3.1 (4)

## Resumo

| Item | Situação |
|---|---|
| Núcleo: cliente do Suwayomi-Server, fonte MangaDex, política de rede para servidor pessoal, limitador de taxa, migração, busca global | ✅ **71/71 testes** no Linux (14 novos), incluindo o teste ao vivo do índice |
| App: instalar/atualizar/remover extensões, conexão com o servidor (senha no Keychain), MangaDex, busca global, migração | ⚠️ Escrito e com sintaxe validada; **aguardando o CI no Xcode 26** |
| Testes contra um Suwayomi real e a API real do MangaDex | ⏳ Não foi possível neste ambiente (rede restrita): as respostas foram simuladas a partir do código-fonte do Suwayomi e de respostas reais da API do MangaDex. **Precisa de teste no seu PC/iPhone** |

## Como ficou a experiência

- **Explorar › Extensões**:
  - sem servidor: catálogo de metadados e o botão *Conectar servidor de extensões*;
  - com servidor: seções *Atualizações*, *Instaladas* e *Disponíveis*, com **Instalar / Atualizar / Remover**, filtro de idioma (padrão pt-BR), busca e opção 18+.
- **Explorar › Fontes**: as fontes instaladas no servidor e o **MangaDex** aparecem por idioma, com fixar, "Último usado", populares/recentes e busca por fonte.
- **Busca global** (lupa em Explorar): pesquisa nas fontes do seu idioma, multi-idioma e fixadas, ou em todas.
- **Migrar**: pela aba *Explorar › Migrar* ou pelo menu ⋯ do título. Copia categorias, capítulos lidos e marcadores.
- **Leitura online**: as mesmas funções do leitor local (zoom, modos, progresso, histórico), com imagens em cache.

## Arquivos novos

- Núcleo: `FYSources/Suwayomi.swift`, `FYSources/MangaDexSource.swift`, `FYServices/Migration.swift`; `FYCore/HTTPClient.swift` ganhou `HTTPRequest`/POST, `RequestPolicy` e `RateLimiter`.
- App: `App/KeychainStore.swift`, `Features/Browse/ServerExtensionsView.swift`, `Features/Browse/GlobalSearchView.swift`.
- Docs: `docs/EXTENSION_SERVER.md` (guia de instalação no Windows e segurança) e `TECHNICAL_DECISIONS.md` §12.

## Testes novos (núcleo)

- `SuwayomiTests` (6): normalização do endereço; política de host/porta/HTTP e Basic Auth; extensões e fontes (a fonte local do servidor é ocultada); navegação → capítulos → páginas; erro 401 compreensível; GraphQL `addExtensionStore`.
- `MangaDexTests` (5): busca (título no idioma, autor, capa, filtros 18+); capítulos (omite externos, credita grupos); páginas via `at-home` com marcação de relatório; 429 compreensível; limitador de taxa.
- `SourceMigrationTests` (3): migração com lidos, marcadores e categorias; recusa de migração para si mesmo; busca global com ordem preservada e falha isolada.

Log: `docs/test-results/phase3-core-linux.txt`.

## Pendências e limitações conhecidas

1. **Compilação no Xcode e testes reais** com Suwayomi e MangaDex: aguardando o CI e o seu teste.
2. Filtros avançados de busca e preferências por fonte (como idioma ou qualidade em cada extensão) ainda não são expostos. A busca simples funciona.
3. Fontes protegidas por Cloudflare ou login dependem do suporte do próprio Suwayomi (WebView no servidor).
4. Se um nó MangaDex@Home falhar, o "Tentar novamente" reutiliza a mesma URL. Pedir um novo `baseUrl` automaticamente fica para depois.
5. Modo `ui_login` (JWT) do Suwayomi não é suportado; use `none` na rede local ou `basic_auth`.
6. Komga e "Atualizações em segundo plano" ficam para os próximos incrementos (Fase 4 inclui downloads offline das fontes online).

## Próximos passos

1. Push → CI. Depois, no PC: instalar o Suwayomi (`docs/EXTENSION_SERVER.md`), conectar pelo app, adicionar o repositório Keiyoushi, instalar uma extensão pt-BR e ler um capítulo.
2. Testar o MangaDex sem servidor: Explorar › Fontes › MangaDex → buscar → ler.
3. **Fase 4:** downloads de capítulos das fontes online para leitura offline, atualizações em segundo plano, Komga.

## Incremento 0.3.1 — Repositórios de extensões (como no Tachimanga)

| Item | Situação |
|---|---|
| Núcleo: vários repositórios, cache por repositório, API GraphQL de repositórios do Suwayomi, sincronização, links `tachiyomi://add-repo` | ✅ **84/84 testes** no Linux (13 novos; 1 teste ao vivo opcional pulado) |
| Índice real do FelipeGFA decodificado pelo FreeYomi | ✅ "FelipeGFA", selo FGFA, 1.383 extensões, site e Discord |
| Tela "Repositórios de extensões" e confirmação ao adicionar | ⚠️ Sintaxe validada; **aguardando o CI** (novo teste de interface `testExtensionRepositoriesScreen`) |

**Como usar:** *Explorar › Extensões › Repositórios de extensões* → **Adicionar repositório** → colar `https://github.com/FelipeGFA/extensoes/raw/repo/index.pb` → **Verificar** → **Adicionar**. Com o servidor conectado, o repositório também vai para o Suwayomi-Server, e as extensões dele aparecem em *Explorar › Extensões* com o botão **Instalar** e o selo FGFA.

**Arquivos:**
- Novos: `FYSources/ExtensionRepositories.swift`, `Features/Browse/RepositoriesView.swift`, `Tests/FYSourcesTests/RepositoryTests.swift`.
- Alterados: `ExtensionCatalog.swift` (cache por repositório, `refreshAll`), `Suwayomi.swift` (GraphQL), `AppSettings.swift`, `AppModel.swift`, `ExtensionCatalogView.swift`, `ServerExtensionsView.swift`, `MoreView.swift`, `RootTabView.swift`, `project.yml` (esquemas de URL, versão 0.3.1).

**Decisão:** ver `TECHNICAL_DECISIONS.md` §13, inclusive por que as extensões continuam rodando no servidor e não dentro do iPhone.

Log: `docs/test-results/phase3.1-core-linux.txt`.
