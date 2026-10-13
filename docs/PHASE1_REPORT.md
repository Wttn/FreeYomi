# Relatório da Fase 1 — Fundação

Data: 13/10/2026 · Versão: 0.1.0 (1)

## Resumo

| Item | Situação |
|---|---|
| Núcleo `FreeYomiKit` (domínio, SQLite, migrações, protobuf, catálogo, fonte demo, serviços) | ✅ **Compilado e testado: 38/38 testes passando** (Linux, Swift 6.0.3, 3 execuções seguidas, 0 avisos) |
| Índice real do Keiyoushi baixado e decodificado | ✅ 1433 extensões, 139 com pt-BR (teste ao vivo) |
| App SwiftUI (5 abas, design system, Liquid Glass, leitor inicial) | ⚠️ **Código escrito e com sintaxe validada (`swiftc -parse`), mas ainda NÃO compilado no Xcode.** Não há macOS neste ambiente; a compilação ocorre no primeiro push (CI `macos-26`) |
| Projeto Xcode (XcodeGen), CI GitHub Actions, `.ipa` sem assinatura | ✅ Configurado; ⏳ aguardando a primeira execução |
| Instalação em iPhone real | ⏳ Documentada (`INSTALL_IPHONE.md`); ainda não testada |

> Pela regra "uma tela bonita não é evidência", a Fase 1 só pode ser considerada concluída depois que o job iOS do CI ficar verde e o checklist em `INSTALL_IPHONE.md` for executado em um aparelho.

## Funcionalidades concluídas

**Núcleo (testado)**
- Modelos: `Manga`, `Source`, `Chapter`, `Page`, `LibraryEntry`, `MangaCategory`, `ReadingProgress`, `ReadingHistoryEntry`, `DownloadTask`, `AppSettings` (+ `ReaderSettings`).
- SQLite: migrações versionadas, chaves compostas, cascata, WAL, verificação de integridade, recuperação preservando o arquivo corrompido, recusa de esquema futuro.
- Repositórios: biblioteca (busca com curingas escapados, filtro por categoria, 4 ordenações, não lidos, última leitura), capítulos (upsert que preserva lido/marcador), progresso (página + deslocamento + concluído → marca como lido), histórico (tempo acumulado, limpar tudo/por título), categorias (CRUD/reordenar), downloads (sem duplicatas), preferências tolerantes.
- Catálogo: gzip (com limite anti-bomba), protobuf próprio, `repo.json → index_v2`, formato legado detectado, HTTPS obrigatório (também após redirecionamento), cache offline com aviso do erro de rede, compatibilidade "Requer Android".
- Fonte de demonstração local (4 títulos fictícios rotulados), `SourceRegistry` com fontes planejadas.
- Regras do leitor: zonas de toque D→E / E→D / invertidas, limites e pré-carga.
- Segurança: `Redactor` (credenciais em URLs), `URLPolicy`, `PathSanitizer` (zip slip).

**App (escrito, aguardando compilação)**
- Abas Biblioteca, Atualizações, Explorar, Histórico e Mais, mapeadas a partir das capturas.
- Biblioteca: grade/lista, itens por linha 1–6, emblemas, categorias, busca, ordenação, seleção em lote, menu contextual.
- Detalhes do título: adicionar/remover, continuar leitura, capítulos com lido/marcador por gesto.
- Leitor: 5 modos, zonas de toque, controles em vidro, barra de páginas, capítulo anterior/próximo, retomada da posição, tela sempre ativa, histórico com duração, Reduce Motion.
- Histórico: linhas como na referência, retomar, remover com confirmação, limpar tudo, modo anônimo.
- Explorar: fontes por "Último usado"/idioma/fixadas, catálogo de extensões, migrar (informativo).
- Mais: sem paywall; Aparência, Biblioteca, Leitor, Extensões, Segurança, Informações de leitura, Transferências, Ajuda e Sobre funcionais; Sincronizar, Rastreamento e Backup como "em desenvolvimento".
- Liquid Glass nativo no iOS 26 com fallback; tema claro/escuro/automático.
- 5 testes de interface (XCUITest).

## Critérios de aceitação (seção 16)

| # | Critério | Situação |
|---|---|---|
| 1 | Abre sem internet | 🟡 Lógica garantida (bootstrap sem rede; teste de interface pronto) — falta rodar no simulador |
| 2 | Biblioteca persiste após reabrir | ✅ `testLibrarySurvivesReopen` |
| 3 | Importar arquivo local | ⏳ Fase 2 (proteção zip slip já testada) |
| 4 | Abrir título e navegar entre páginas | 🟡 Núcleo ✅ (`testChaptersAndPages`); interface aguardando o CI |
| 5 | Progresso salvo e restaurado | ✅ `testProgressAndHistory` (inclui deslocamento de rolagem) |
| 6 | Modos horizontal e vertical | 🟡 Implementados; aguardando o CI/aparelho |
| 7 | Catálogo baixado e decodificado | ✅ Amostra real + índice ao vivo |
| 8 | Fontes incompatíveis sem falhas | ✅ `testAllCatalogExtensionsRequireAndroidUntilAdapterExists`, `testMissingSourceIsReportedNotCrashing` |
| 9 | Downloads lidos offline | ⏳ Fase 4 |
| 10 | Erros de rede compreensíveis | ✅ Mensagens em pt-BR testadas (HTTP 404, cache offline) |
| 11 | Tema claro e escuro | 🟡 Implementado; aguardando execução |
| 12 | Liquid Glass onde suportado | 🟡 Implementado com APIs nativas; aguardando build no Xcode 26 |
| 13 | Sem anúncios/compras/paywall | ✅ Não existe código nem dependência para isso; teste de interface verifica a tela Mais |
| 14 | Instalação em iPhone real | ⏳ Documentada; não testada |
| 15 | Build e testes automatizados no CI | 🟡 Configurado; aguardando o primeiro push |

## Resultados de teste

`docs/test-results/phase1-core-linux.txt` — 38 testes em 10 suítes, 0 falhas:

- `GzipTests` (3), `ProtobufTests` (4), `SecurityTests` (3)
- `MigrationTests` (2), `PersistenceTests` (8)
- `CatalogDecoderTests` (5), `CatalogClientTests` (4, incluindo o teste ao vivo), `DemoSourceTests` (4), `ReaderNavigationTests` (2)
- `LibraryServiceTests` (3)

## Problemas conhecidos

1. **App ainda não compilado** (ver acima). Podem aparecer erros de tipo em SwiftUI no primeiro build; serão corrigidos antes de iniciar a Fase 2.
2. Os testes de interface localizam elementos pelos rótulos de acessibilidade e podem precisar de ajustes após a primeira execução.
3. O leitor ainda não tem zoom por gesto nem ajuste à largura/altura (opções salvas, mas a exibição é sempre "página inteira").
4. Imagens remotas usam `AsyncImage` sem cache em disco nem cabeçalhos por fonte (sem impacto na Fase 1, que não tem fontes remotas).
5. No modo vertical, a posição é salva por página; o deslocamento dentro da página (já suportado pelo modelo e pelo banco) ainda não é capturado pela interface.
6. Ícone do app provisório.
7. Durante os testes, uma falha conhecida do FoundationNetworking no Linux (ao desalocar `URLSession`) derrubava o teste ao vivo de forma intermitente. Foi corrigida com uma sessão compartilhada; 3 execuções seguidas passaram.

## Decisões relevantes

SwiftUI nativo (não Expo); SQLite próprio (não SwiftData); decodificador protobuf próprio; zero dependências em tempo de execução; extensões Android nunca executadas; Apache-2.0; iOS 17 como mínimo, com Liquid Glass no 26. Detalhes em `TECHNICAL_DECISIONS.md`.

## Próximas tarefas recomendadas

1. Criar o repositório público no GitHub, fazer o push e corrigir o que o job `ios` apontar até ficar verde.
2. Instalar o `.ipa` no iPhone e preencher o checklist de `INSTALL_IPHONE.md`.
3. **Fase 2:** importação de CBZ/ZIP (extração segura com zlib + `PathSanitizer`) e de pastas pelo seletor de arquivos; leitor com zoom (`UIScrollView`), ajustes à largura/altura, pipeline de imagens com cache em disco, pré-carga e liberação de memória; captura do deslocamento vertical; testes de memória.
4. **Fase 3:** adaptador Komga (servidor pessoal, credenciais no Keychain, nunca em logs/backups); avaliar o cliente para servidor de extensões do próprio usuário; migrar entre fontes.
