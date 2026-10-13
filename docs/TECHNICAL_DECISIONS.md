# Decisões técnicas, riscos e limitações

Registro das análises feitas **antes** da implementação (seção 3 do briefing) e das decisões que delas resultaram. Data da análise: 13/10/2026.

---

## 1. Repositórios de referência e licenças

| Projeto | O que foi inspecionado | Licença encontrada | Consequência para o FreeYomi |
|---|---|---|---|
| **Mihon** (`mihonapp/mihon`) | Código-fonte (clone raso), em especial `data/extension/model/NetworkExtensionStore.kt` e `service/ExtensionStoreService.kt` | **Apache-2.0** | Usado como referência funcional e para confirmar o esquema do índice. **Nenhuma linha de código foi copiada**; os números de campo do protobuf são fatos de interoperabilidade. |
| **Tachimanga** (`tachimanga/tachimanga`) | O repositório público contém **apenas um `README.md`** (1 commit) | **Nenhuma licença publicada** → todos os direitos reservados por padrão | Nada é reutilizado: nem código, nem ícones, nem textos, nem marca. Só a experiência *observável* (capturas fornecidas) orienta a estrutura das telas. |
| **Keiyoushi** (`keiyoushi/extensions`, branch `repo`) | `repo.json`, `index.pb` (baixados e decodificados) | `extensions-source`: **Apache-2.0** | Consumimos apenas **metadados** públicos. Uma amostra de 10 extensões classificadas como "seguras" foi incluída como fixture de teste. |
| **FelipeGFA** | — | — | A URL não foi fornecida na configuração do projeto. **Não foi integrado** e nenhum endpoint foi presumido. Quando a URL for informada, basta cadastrá-la em *Mais › Extensões* se ela publicar um índice compatível (protobuf `index_v2` ou `repo.json`). |

O README do Tachimanga afirma suporte a ZIP/CBZ, EPUB e Komga — isso confirmou as prioridades da seção 10 do briefing.

## 2. Funcionalidades do Mihon/Tachimanga × viabilidade no iOS

| Funcionalidade | Viável no iOS? | Observação |
|---|---|---|
| Biblioteca, categorias, filtros, ordenação, seleção em lote | ✅ | Implementado na Fase 1 (núcleo + UI). |
| Histórico com tempo de leitura e modo anônimo | ✅ | Implementado na Fase 1. |
| Leitor paginado/vertical/webtoon | ✅ | Versão inicial na Fase 1; zoom e escalas na Fase 2. |
| Downloads offline | ✅ | Tabela e regras (sem duplicatas) prontas; gerenciador na Fase 4 via `URLSession` em segundo plano. |
| Atualização da biblioteca em segundo plano | ⚠️ Parcial | O iOS só oferece `BGAppRefreshTask`/`BGProcessingTask`, com execução decidida pelo sistema. Não há serviço contínuo como no Android. |
| **Instalar extensões (APK)** | ❌ | Ver seção 4. |
| Rastreadores (AniList, MAL…) | ✅ | OAuth com `ASWebAuthenticationSession`. Planejado, gratuito. |
| Backup compatível com Mihon (`.tachibk`) | ⚠️ | Formato protobuf+gzip documentado no código do Mihon; exige conversor dedicado. **Não prometido** até ser implementado e testado (Fase 5+). |
| Controle de brilho | ⚠️ | `UIScreen.brightness` existe, mas `UIScreen.main` foi descontinuado em versões recentes; será implementado via `windowScene.screen` na Fase 2. |
| Orientação travada por leitor | ⚠️ | Possível com `UIWindowScene.requestGeometryUpdate`; Fase 2. |

## 3. O índice `index.pb` do Keiyoushi

**Como foi verificado:** o arquivo foi baixado (110 575 bytes), identificado pelo cabeçalho `1F 8B` como **gzip**, descomprimido (719 948 bytes) e decodificado "às cegas" no formato de fio do protobuf. O resultado foi conferido com o modelo anotado com `@ProtoNumber` no Mihon. O `repo.json` do mesmo branch aponta para ele pelo campo `index_v2`.

Esquema (mensagem raiz `ExtensionStore`):

```
1   name: string                  ("Keiyoushi")
2   badgeLabel: string            ("KEI")
3   signingKey: string            (SHA-256 do certificado de assinatura dos APKs)
4   contact: { 1 website, 2 discord }
101 extensionList: { 1 repeated Extension }      (opcional)
102 extensionListUrl: string                     (opcional, lista em arquivo separado)

Extension: 1 name, 2 packageName, 3 resources, 4 extensionLib ("1.4"/"1.6"),
           5 versionCode (int64), 6 versionName, 7 contentWarning, 8 repeated Source
Resources: 1 apkUrl, 2 iconUrl, 501 jarUrl   ← 501 está no arquivo, mas não no modelo do Mihon
Source:    1 id (int64, usa os 64 bits), 2 name, 3 language, 4 homeUrl,
           5 repeated mirrorUrls, 7 message   (6 está comentado no Mihon)
ContentWarning: 0 UNSPECIFIED, 1 SAFE, 2 MIXED, 3 NSFW
```

Números da sincronização de 13/10/2026: **1433 extensões, 2422 fontes, 139 extensões com fontes pt-BR**; avisos de conteúdo: 578 seguras, 472 mistas, 383 adultas.

**Decisão:** decodificador protobuf próprio (~150 linhas, `FYCore/Protobuf.swift`) em vez do SwiftProtobuf. O esquema é pequeno, não há geração de código, campos desconhecidos são ignorados (compatibilidade futura) e há proteção contra dados malformados (limite de aninhamento, comprimentos validados, limite de 64 MB no gzip). Testado com amostra real, dados sintéticos e o índice ao vivo.

## 4. Extensões Android × adaptadores iOS

As extensões do Keiyoushi são **APKs Android com código Kotlin** que dependem de APIs Android, OkHttp, Jsoup e da `extensions-lib`. O campo `jarUrl` (501) indica um `.jar` para execução em uma JVM.

O FreeYomi **não** executa esse código, porque:

1. O iOS não tem JVM nem ART; embutir uma seria pesado e, para código baixado, viola a diretriz 2.5.2 da App Store (download de código executável).
2. O briefing proíbe executar código arbitrário de fontes externas.
3. Executar extensões sem sandbox daria a terceiros acesso irrestrito ao app.

**Arquitetura adotada:** protocolo `MangaSource` (em `FYSources`) com **adaptadores Swift nativos**, revisados e compilados junto com o app. O catálogo é exibido para transparência, e cada extensão aparece como **"Requer Android"** até que exista um adaptador registrado em `CompatibilityResolver.nativeAdapters`. Nenhuma extensão é declarada compatível só porque aparece no índice (testado).

**Caminho futuro legítimo (a avaliar na Fase 3):** cliente para um **servidor pessoal** do próprio usuário que execute extensões em JVM (por exemplo, um servidor no estilo Suwayomi). O código roda fora do iPhone, no servidor do usuário — mesmo modelo do Komga. Ainda não analisado em detalhe; não prometido.

## 5. Liquid Glass (iOS 26)

APIs nativas usadas, todas atrás de `#if compiler(>=6.2)` + `if #available(iOS 26.0, *)` em `DesignSystem/Glass.swift`:

- `glassEffect(_:in:)` com `Glass.regular` e `.interactive()` — controles flutuantes do leitor e barra de seleção da biblioteca.
- `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` — botões de ação.
- `tabBarMinimizeBehavior(.onScrollDown)` — a tab bar encolhe ao rolar.
- `TabView`, `NavigationStack`, `toolbar`, `searchable`, `Menu` e `contextMenu` **nativos**. Compilados com o SDK do iOS 26, recebem o Liquid Glass do sistema automaticamente, sem componentes recriados.

**Fallback (iOS 17/18):** `.ultraThinMaterial`, `.borderedProminent`/`.bordered` e a tab bar translúcida padrão.

**Regra de uso:** vidro apenas em barras e controles flutuantes. Páginas do mangá e textos longos ficam sobre fundo opaco (o leitor usa preto puro).

Alvo mínimo: **iOS 17**, necessário para `@Observable`, `ContentUnavailableView`, `scrollPosition(id:)`, `toolbarTitleDisplayMode(.inlineLarge)` e `containerRelativeFrame`.

## 6. Stack: SwiftUI × React Native/Expo

| Critério | SwiftUI nativo | React Native + Expo |
|---|---|---|
| Liquid Glass | APIs oficiais completas | Só via módulos nativos de terceiros, com cobertura parcial; a tab bar e as toolbars nativas não vêm "de graça" |
| Leitor de imagens (memória, zoom, prefetch) | `UIScrollView`/SwiftUI, controle fino | Ponte JS↔nativo; exige bibliotecas nativas para bom desempenho |
| Desenvolvimento no Windows | Edição no VS Code; build só em macOS (CI) | Expo Go/EAS Build facilitam, mas o build iOS também roda em macOS remoto |
| Testes da lógica fora do Mac | ✅ Núcleo em Swift puro roda em Linux/Docker | ✅ JS roda em qualquer lugar |
| Dependências / licenças | Zero dependências em tempo de execução | Centenas de pacotes npm para auditar |

**Decisão: SwiftUI.** A principal vantagem do Expo (build na nuvem) é compensada pelo CI no GitHub Actions. O Liquid Glass completo e o desempenho do leitor exigem acesso nativo. Para manter o fluxo no Windows, a lógica fica em um pacote Swift que **compila e é testado em Linux** (Docker/WSL), e só a camada SwiftUI exige macOS.

## 7. Persistência: SQLite × SwiftData

**Decisão: SQLite direto** (biblioteca do sistema, domínio público), com um wrapper próprio (`FYData/SQLiteDatabase.swift`).

- Migrações explícitas e versionadas (`PRAGMA user_version`), cada uma em transação; o app recusa abrir um banco criado por uma versão mais nova, em vez de corrompê-lo.
- Chaves compostas `UNIQUE(source_id, key)` em títulos e `UNIQUE(manga_id, key)` em capítulos; IDs locais estáveis; `ON DELETE CASCADE`.
- WAL + `synchronous=NORMAL`; `PRAGMA quick_check` na abertura. Um arquivo corrompido é **renomeado** (`.corrupt-<timestamp>`, nunca apagado) e um banco novo é criado, com aviso ao usuário.
- Preferências em JSON com decodificação tolerante: campos novos ou inválidos voltam ao padrão.
- SwiftData foi descartado porque é exclusivo das plataformas Apple (impossível testar em Linux/Windows), oferece menos controle sobre as migrações e dificultaria o backup.

## 8. Compilação a partir do Windows

- O `.xcodeproj` é **gerado** por XcodeGen a partir de `project.yml` (sem conflitos de merge, editável no VS Code).
- **GitHub Actions** (`.github/workflows/ci.yml`):
  - job Linux (`swift:6.1-noble`): testes do núcleo;
  - job `macos-26` (Xcode 26): `xcodegen`, testes do núcleo no macOS, testes de interface no simulador, `archive` sem assinatura → artefato `FreeYomi-unsigned.ipa`.
- A assinatura é feita depois, no Windows, com a conta Apple do próprio usuário (ver `INSTALL_IPHONE.md`). Nenhum certificado fica no repositório.

## 9. Licença do FreeYomi

**Apache-2.0.** É permissiva, compatível com o Mihon (fonte de inspiração), com SQLite e zlib, e com a distribuição pela App Store/TestFlight. Licenças GPL têm conflito conhecido com os termos da App Store. A gratuidade é garantida pela arquitetura (não existe código de compra, assinatura ou bloqueio) e por política do projeto (`CONTRIBUTING.md`).

## 10. Riscos e limitações conhecidos

| Risco | Impacto | Mitigação |
|---|---|---|
| **A camada SwiftUI ainda não foi compilada** (não há macOS no ambiente da Fase 1) | Alto até o primeiro CI | O núcleo foi compilado e testado (38/38); os arquivos SwiftUI passaram em `swiftc -parse`. O primeiro push dispara o build no Xcode 26, e eventuais erros de tipo serão corrigidos antes da Fase 2. |
| Runner `macos-26` indisponível ou renomeado | Médio | Trocar `runs-on` para `macos-latest` com Xcode 26 instalado; sem Xcode 26, o fallback de materiais compila (graças ao `#if compiler`). |
| Sem fontes online reais na Fase 1 | Médio | Por decisão do briefing ("quando tecnicamente viável e autorizado"). Próximas: Komga (servidor do usuário) e arquivos locais. |
| Atualizações em segundo plano limitadas pelo iOS | Baixo | Documentado; atualização manual sempre disponível. |
| Conta Apple gratuita: assinatura dura 7 dias | Baixo | Reassinar com Sideloadly/AltStore; ou Apple Developer Program (pago, da Apple, não do app). |
| Mudança no esquema do `index.pb` | Baixo | Campos desconhecidos são ignorados; cache local; teste ao vivo (não bloqueante) no CI detecta mudanças. |

---

## 11. Decisões da Fase 2 (biblioteca local e leitor)

| Tema | Decisão | Motivo |
|---|---|---|
| Leitura de ZIP/CBZ/EPUB | Leitor próprio (`FYCore/ZipArchive.swift`) sobre a zlib do sistema | Sem dependências; entrada tratada como não confiável: limites de entradas/tamanho/taxa de compressão, CRC-32 obrigatório, tamanho descomprimido exato, recusa de ZIP criptografado, ZIP64 e multi-volume com mensagem clara |
| "Zip slip" | Nenhum nome vindo do arquivo vira caminho de destino: as páginas são renumeradas (`c0001/0001.jpg`) em uma pasta criada pelo app; nomes inseguros são ignorados e relatados | Elimina a classe de ataque por construção, além do `PathSanitizer` |
| Validação de imagens | Pelo conteúdo (assinatura JPEG/PNG/GIF/WebP/HEIC/AVIF/BMP), não pela extensão | Evita gravar arquivos disfarçados |
| CBR/RAR e CB7/7z | **Não suportados**; o app explica e sugere converter para CBZ | A licença do UnRAR não é open source compatível; 7z exigiria dependência grande. Pode ser reavaliado com uma biblioteca de licença compatível |
| EPUB | Só EPUBs de imagens (mangás/quadrinhos): ordem do *spine*, `<img src>` e `<image xlink:href>` | EPUB de texto exige um motor de layout próprio (fora do escopo de um leitor de mangás); recusado com mensagem clara |
| Estrutura de importação | Arquivo → 1 capítulo (ou 1 por pasta interna, se for um volume com pastas); pasta de imagens → 1 capítulo; pasta com subpastas/CBZs → 1 capítulo por item; metadados de `ComicInfo.xml` | Cobre os formatos mais comuns de coleções pessoais |
| Duplicatas | Impressão digital (nome + tamanho + páginas); reimportar não duplica | Requisito "evitar duplicados" |
| Armazenamento | Páginas extraídas em `Application Support/FreeYomi/LocalFiles` (o original não é alterado) | Leitura offline rápida, sem reabrir o ZIP a cada página |
| Imagens | `ImagePipeline` com ImageIO: decodificação já reduzida à largura da tela (2× para zoom), pela LARGURA no caso de faixas de webtoon, teto de ~48 MP; `NSCache` limitado a 160 MB e esvaziado em alerta de memória; cache em disco de 300 MB (LRU) para imagens remotas; requisições compartilhadas; pré-carga configurável e cancelada ao sair | Requisitos de desempenho/memória da seção 8 |
| Zoom | `UIScrollView` nativo (pinça e toque duplo) nos modos paginados; sem zoom, gestos horizontais passam para o paginador | Componente de zoom do sistema; suave e acessível |
| Modos verticais | Leitor em UIKit (`VerticalPagesView`: `UIScrollView` com páginas posicionadas pela proporção conhecida, carregamento de ±2 páginas ao redor da visível e descarte das demais, zoom de 1× a 3× do conjunto) | A primeira versão com `LazyVStack` + rastreamento de geometria travava a thread principal no fim do capítulo, como mostraram os testes de interface. Em UIKit o layout é calculado uma vez, sem ciclos |
| Posição na rolagem vertical | Página que cruza o topo (busca binária nas molduras) + deslocamento 0–1 dentro dela, salvos 1 s após parar de rolar, ao trocar de capítulo, ao sair e ao ir para segundo plano; restauração **exata** por `contentOffset` | Recuperação após encerramento inesperado |
| Layout estável no vertical | Proporções das páginas locais lidas só do cabeçalho (sem decodificar) antes de exibir | Evita "saltos" ao restaurar a posição |

---

## 12. Decisões da Fase 3 (extensões e leitura online)

**Pedido:** instalar extensões e buscar/ler online "como no Tachimanga".

**Restrição:** as extensões do catálogo são código Kotlin/JVM. Executá-las no iPhone exigiria embutir uma JVM e baixar código executável, o que contraria a diretriz 2.5.2 da App Store e a regra do projeto de não executar código de terceiros com acesso ao app (§4).

**Decisão — dois caminhos complementares:**

| Caminho | Como funciona | Vantagens | Limites |
|---|---|---|---|
| **Servidor de extensões** (Suwayomi-Server, MPL-2.0, *não* embutido no app) | O usuário roda o servidor no PC/NAS; o FreeYomi usa a API REST v1 (e uma mutação GraphQL) para instalar extensões, navegar, buscar e ler | Catálogo completo (todas as extensões, inclusive pt-BR); nenhum código de terceiros no iPhone | Exige um computador ligado; fora de casa, VPN ou HTTPS |
| **Fontes nativas** (Swift) | Adaptadores escritos e revisados no repositório | Funcionam sem servidor | Uma por vez; só fontes com API pública e termos que permitam apps de terceiros |

- **MangaDex** foi a primeira fonte nativa. Os termos (api.mangadex.org/docs) permitem apps de terceiros sem anúncios nem serviços pagos, com crédito ao MangaDex e aos grupos. Implementado: User-Agent real, 4 req/s, 40/min no `at-home`, imagens via `at-home` (sem cabeçalho de autenticação) e relatório para nós MangaDex@Home. Capítulos só externos (ex.: MANGA Plus) são omitidos, e o conteúdo adulto segue a preferência 18+.
- **Segurança de rede:** a nova `RequestPolicy.personalServer` aceita HTTP apenas para o host e a porta configurados, inclusive após redirecionamentos. As demais requisições continuam só em HTTPS. ATS: `NSAllowsLocalNetworking` (sem `NSAllowsArbitraryLoads`). A senha do servidor fica no Keychain (`AfterFirstUnlockThisDeviceOnly`).
- **Chave dos capítulos do servidor:** a URL do capítulo na fonte (estável), não o índice do Suwayomi, que muda quando saem capítulos novos.
- **Migração:** copia categorias, capítulos lidos (até o maior número lido) e marcadores (por número); preserva o original e o histórico dele.
- **Busca global:** até 4 fontes simultâneas; a falha de uma fonte não afeta as outras.
- **Komga:** adiado para o próximo incremento. O pedido priorizou extensões e leitura online.

## 13. Repositórios de extensões como no Tachimanga (0.3.1)

**Pedido:** uma tela equivalente à "Repositórios de extensões" do Tachimanga, onde se adiciona um repositório (ex.: Keiyoushi, FelipeGFA) e se instalam as extensões dele.

**O que foi feito:**

- **Vários repositórios** (`AppSettings.extensionRepositories`; o antigo `catalogURL` é migrado para a lista). Cada repositório tem cartão com nome, selo (ex.: KEI, FGFA), endereço, **Copiar**, **Discord/Site** (dados do próprio índice) e menu ⋯ (copiar, abrir site, Discord, remover). Há reordenação, "Adicionar repositório" e "Encontrar repositório" (sugestões que só preenchem o campo).
- **Adicionar = verificar antes.** O índice é baixado e decodificado antes da confirmação. A tela mostra nome, selo, total de extensões, quantas têm fontes pt-BR ou 18+ e a impressão digital da chave de assinatura. Só HTTPS; `index.min.json` (formato antigo) é recusado com explicação.
- **Sincronização com o servidor.** Com o Suwayomi-Server conectado, o app usa a API GraphQL de repositórios do próprio servidor, conferida no código (`graphql/queries/ExtensionStoreQuery.kt`, `graphql/mutations/ExtensionStoreMutation.kt`, commit `635751a`): `extensionStores`, `addExtensionStore`, `removeExtensionStore` e `extensions { pkgName storeIndexUrl }` (para o selo do repositório em cada extensão). Os repositórios do app que faltam no servidor são enviados a ele, e os que só existem no servidor entram na lista do app. Endereços equivalentes do GitHub (`github.com/…/raw/…` e `raw.githubusercontent.com/…`) contam como o mesmo repositório.
- **Links "Adicionar ao Mihon".** O app aceita `tachiyomi://add-repo?url=…` e `mihon://extension-store?url=…`, os formatos tratados pelo Mihon em `MainActivity.isAddExtensionStoreIntent`, além de `freeyomi://add-repo?url=…`. O link só abre a tela de confirmação; nada é adicionado sozinho. Observação: se outro app instalado também registrar `tachiyomi://`, o iOS escolhe um deles.
- **Instalação:** continua no servidor (Explorar › Extensões › Instalar/Atualizar/Remover). As extensões de todos os repositórios aparecem juntas, com o selo de origem.

**Por que o iPhone não executa as extensões, como o Tachimanga parece fazer.** O Tachimanga tem código fechado. Pelo comportamento, ele embute um ambiente que executa as extensões Kotlin/JVM dentro do app; não há como confirmar como, nem reaproveitar nada (o repositório público dele não tem licença). Fazer o mesmo no FreeYomi exigiria:

1. baixar e executar código de terceiros dentro do app, o que contraria duas regras do briefing ("não executar código arbitrário proveniente de fontes externas" e "não execute extensões externas com acesso irrestrito ao aplicativo") e a diretriz 2.5.2 da App Store (o app só poderia ser distribuído por sideload/AltStore);
2. um runtime JVM/Dalvik para iOS sem JIT (o iOS proíbe JIT para apps comuns), além de reimplementar as APIs Android usadas pelas extensões (OkHttp, Jsoup, WebView, SharedPreferences, etc.).

Isso só será considerado com decisão explícita do mantenedor, abrindo mão dessas regras e da App Store. Mesmo assim, entraria como modo opcional e isolado (as extensões sem acesso à biblioteca nem ao Keychain), e só depois de um protótipo provar que é viável. Até lá, o caminho suportado é o servidor de extensões.

## 14. Repositórios adicionados pelo usuário e extensões nativas (0.4.0)

Revisão de §13: o app deixa de trazer repositório padrão, sugestões e a fonte MangaDex ativada. Os repositórios passam para o banco (migração 2), os formatos `index.min.json`, `repo.json`, `index.json`, `index.pb` e `freeyomi.repository.v1` são aceitos, e extensões nativas (manifestos declarativos interpretados por adaptadores Swift do app, com SHA-256) podem ser instaladas no iPhone. Extensões Android continuam incompatíveis no aparelho. Análise completa, licenças, segurança e limitações: [`EXTENSIONS_ARCHITECTURE.md`](EXTENSIONS_ARCHITECTURE.md).
