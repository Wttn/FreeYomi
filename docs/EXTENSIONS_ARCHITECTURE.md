# Arquitetura de repositórios e extensões

Versão 0.5.0 · análise de 13/10/2026, runtime Java em 14/10/2026

Este documento registra a análise técnica obrigatória (seção 1 do pedido), as decisões tomadas, as licenças envolvidas e as limitações. Ele substitui as partes de `TECHNICAL_DECISIONS.md` §13 que tratavam de repositório padrão e sugestões.

## 1. Regra fundamental

O FreeYomi **não traz** repositórios de extensões, catálogos de fontes recomendadas, links para fontes de terceiros nem extensões instaladas por padrão. A tabela abaixo mostra como isso foi aplicado e testado.

| Antes (0.3.1) | Agora (0.4.0) | Teste |
|---|---|---|
| Keiyoushi pré-configurado em `AppSettings` e enviado ao servidor automaticamente | Lista vazia. Instalações que tinham **só** esse item pré-configurado perdem o item, com aviso. Listas editadas pelo usuário são mantidas inteiras | `testNothingIsPreconfigured`, `testLegacyPreconfiguredRepositoryIsRemovedButUserChoicesAreKept`, `testNoPreconfiguredSourcesOrRepositories` (UI) |
| "Encontrar repositório" com sugestões (Keiyoushi, FelipeGFA) | Removido. A tela vazia mostra só a mensagem neutra | `testNoPreconfiguredSourcesOrRepositories` (UI) |
| Fonte MangaDex ativada de fábrica, com `api.mangadex.org` no código | O código do adaptador continua no app, mas sem nenhum endereço: só funciona quando o usuário instala um manifesto de um repositório dele | `testNothingIsPreconfigured`, `testInstallsAndUsesCompatibleSource` |
| Teste ao vivo contra um repositório real no CI | Removido do CI. Opcional e local: `FY_LIVE_INDEX_URL=<endereço> swift test --filter testLiveRepositoryIndex` | — |

A única string de repositório que sobrou no código (`ExtensionManager.legacyPreconfiguredRepository`) serve só para **reconhecer e remover** o padrão antigo durante a migração. Ela nunca é oferecida ao usuário.

## 2. Arquitetura encontrada

```
App (SwiftUI)  ── AppModel ──► ExtensionManager (FYServices)
                                 ├─ ExtensionCatalogClient (FYSources): download, limites, formatos, cache
                                 ├─ NativeExtensionInstaller + AdapterRegistry (FYSources)
                                 ├─ JVMExtensionInstaller + JVMExtensionLoader (FYSources) ─► JVMBridge
                                 │     └─ EmbeddedJVM (app, C/JNI) ─► OpenJDK Mobile + fy-runtime.jar
                                 ├─ DataStore (FYData): extension_repositories, installed_extensions
                                 └─ SourceRegistry (FYSources): fontes ativas (protocolo MangaSource)
               ── SuwayomiClient ─► servidor de extensões do usuário (opcional, extensões Android)
```

- `MangaSource` (protocolo de domínio) separa as fontes da interface e da persistência. A biblioteca, o leitor e os arquivos locais funcionam sem nenhum repositório.
- O núcleo (`Packages/FreeYomiKit`) não depende de UIKit/SwiftUI e roda os testes no Linux, no job `core-linux` do CI.

## 3. Formatos de índice

Conferidos no código do **Mihon** (Apache-2.0, commit `446f6df`): `ExtensionStoreService.kt` e `data/extension/model/*.kt`. Conferidos também nos arquivos publicados de um repositório real (branch `repo`). Nenhuma linha de código foi copiada; nomes e números de campo são fatos de interoperabilidade.

| Formato | Como é reconhecido | Observações |
|---|---|---|
| `index.pb` | Binário (com ou sem gzip) | Mensagem `ExtensionStore`: 1 name, 2 badgeLabel, 3 signingKey, 4 contact{1 website, 2 discord}, 101 extensionList, 102 extensionListUrl. Extension: 1 name, 2 packageName, 3 resources{1 apkUrl, 2 iconUrl, 501 jarUrl}, 4 extensionLib, 5 versionCode, 6 versionName, 7 contentWarning, 8 sources. O campo 501 aparece nos arquivos publicados, mas não no modelo do Mihon. Decodificador próprio (`FYCore/Protobuf.swift`); campos desconhecidos são ignorados. |
| `index.json` | Objeto JSON sem `index_v2`/`meta`/`format` | A mesma mensagem em **JSON proto3**: int64 como texto (`"106004"`) e enums pelo nome (`"CONTENT_WARNING_NSFW"`). Os dois formatos são aceitos. |
| `repo.json` (legado) | Objeto com `index_v2` ou `meta` | Com `index_v2`, segue para o índice novo (até 3 saltos). Sem ele, lê `<pasta>/index.min.json` com os metadados de `meta`. |
| `index.min.json` (legado) | Lista JSON | Como no Mihon, consulta o `repo.json` ao lado para pegar o nome e, se existir, o índice novo. Sem `repo.json` (o caso descrito no guia do Tachimanga), o nome vem do endereço. APK e ícone ficam em `<pasta>/apk/<apk>` e `<pasta>/icon/<pkg>.png`. Nomes de arquivo com `/`, `..` ou esquema são descartados. |
| `freeyomi.repository.v1` | Objeto com `"format": "freeyomi.repository.v1"` | Formato próprio para extensões nativas do iOS (seção 5). Formatos mais novos são recusados com "atualize o app". |

Entradas incompletas (sem `packageName`, por exemplo) são ignoradas e contadas. Um índice sem nome, um JSON truncado, HTML no lugar do índice, protobuf corrompido ou uma lista sem nenhuma entrada válida são **recusados**: o repositório não é salvo.

## 4. Tachimanga e extensões Android

- **Como o Tachimanga faz:** o app embute uma máquina virtual Java e roda um fork do Tachidesk-Server (`tachimanga/Tachidesk-Server`, MPL-2.0) dentro do processo. As extensões publicam, além do APK, um `.jar` (campo `jarUrl`, nº 501 no `index.pb`) com o mesmo código já convertido para bytecode Java, e é esse `.jar` que roda no iPhone.
- **Extensões Mihon/Keiyoushi:** código Kotlin que depende de `extensions-lib`, OkHttp, Jsoup e APIs Android (fornecidas pela camada de compatibilidade do Tachidesk). Código-fonte Apache-2.0.

O FreeYomi 0.5 faz o mesmo (seção 4.1). Extensões que publicam só o APK continuam podendo rodar num **servidor de extensões** do usuário (Suwayomi-Server, ver `EXTENSION_SERVER.md`).

### 4.1 Runtime Java embutido

| Peça | Origem e licença | Onde |
|---|---|---|
| JVM | OpenJDK Mobile (`openjdk/mobile`, commit `c1ed06aa`), interpretador **Zero** (sem JIT, nunca gera código nativo), compilado como biblioteca estática para iOS. GPLv2 (HotSpot) + Classpath Exception (bibliotecas). Dois patches pequenos em `prototype/jvm/patches/apply.py` | `.github/workflows/jvm-ios.yml` |
| Classes do Java | As classes compiladas do OpenJDK Mobile viram um único `lib/modules` (formato jimage 1.1), gerado no CI por `scripts/jimage` (código de leitura/escrita do próprio OpenJDK; o `module-info.class` ganha o atributo `ModulePackages`). `.class` soltos no app quebravam a assinatura (Sideloadly: "macho sign/edit failed"), porque começam com `0xCAFEBABE`, o mesmo número de um Mach-O universal. O CI confere que nenhum arquivo parece Mach-O e assina uma cópia do app | `scripts/prepare-jvm.sh` |
| Runtime das extensões | Fork do Tachidesk-Server do Tachimanga (commit `2e52214`, MPL-2.0) + `freeyomi.FYHost` (`prototype/jvm/host/FYHost.kt`), num único `fy-runtime.jar` | `.github/workflows/jvm-runtime.yml` |
| Ponte | `App/JVM/fyjvm.c` (JNI; uma thread com pilha de 32 MB por chamada) e `App/JVM/EmbeddedJVM.swift` (`JVMBridge`) | app |
| Instalação e fontes | `JVMExtensionInstaller`, `JVMExtensionLoader`, `JVMExtensionSource` (`MangaSource`) | `FYSources/JVMExtensions.swift` |

**Licença:** GPLv2 do HotSpot não é compatível com a distribuição sob Apache-2.0. Esta configuração é para **uso pessoal** (instalação própria, fora da App Store). O app compila sem a JVM quando `JVM/build/JVM.xcconfig` não existe (`scripts/prepare-jvm.sh`), e nesse caso extensões Android voltam a aparecer como incompatíveis.

**Protocolo:** o app envia JSON para `FYHost.call` — `init`, `load {jar, className}`, `popular`, `latest`, `search`, `details`, `chapters`, `pages` — e recebe `{"ok": true, "result": …}` ou `{"ok": false, "error": …}`. Imagens (páginas e capas) são baixadas pelo `URLSession` do app com os cabeçalhos que a fonte declara (`Referer`, `User-Agent`…); cookies e cabeçalhos de conexão não são repassados.

**Instalar** (botão na tela Extensões, só para extensões de repositórios que o usuário adicionou):
1. confere `jarUrl` e `extensions-lib` 1.3–1.6 (as do Tachidesk-Server);
2. baixa o `.jar` com os limites do catálogo (HTTPS, 20 MB, redirecionamento sem rebaixar para HTTP);
3. confere que é um ZIP com classes e lê a classe principal do `AndroidManifest.xml` (texto) que vem no `.jar` — nome de classe validado, pacote igual ao anunciado;
4. **a JVM carrega a extensão e lista as fontes**; só então o registro é gravado (`installed_extensions`, adaptador `jvm-tachiyomi`, manifesto com arquivo, SHA-256 do `.jar`, classe e fontes). Falha em qualquer passo apaga o `.jar` e não grava nada.

**Abrir o app** registra as fontes sem iniciar a JVM. Ela inicia no primeiro uso de uma dessas fontes, e cada `.jar` é carregado uma vez, depois de conferir o SHA-256 gravado. Desinstalar apaga o `.jar` e retira as fontes; biblioteca, progresso e capítulos baixados ficam.

**Limitações:** extensões que exigem WebView (Cloudflare), cookies de login, preferências da fonte ou interceptadores de imagem (imagens embaralhadas) ainda não funcionam; o interpretador é lento na primeira requisição (TLS em Java). O próximo passo é a ponte de rede nativa (`NativeNet`, como no Tachimanga), que troca o TLS do Java pelo `URLSession`.

## 5. Extensões nativas para iOS (adaptadores)

Para que uma fonte funcione no iPhone sem executar código baixado:

1. O **adaptador** é código Swift compilado no app e revisado no repositório (protocolo `SourceAdapter`). Hoje existe um: `mangadex-api-v5`, para APIs compatíveis com a API pública do MangaDex v5.
2. O repositório publica um **manifesto declarativo** (`freeyomi.extension.v1`), só com dados: id, versão, adaptador, versão do adaptador, fontes e configuração (por exemplo, os endereços da API). Nenhum script, expressão ou código.
3. **Instalar** = baixar o manifesto (limite de 256 KB) → conferir o **SHA-256** publicado no índice (quando existir) → validar formato, id, versão anunciada × versão do manifesto, adaptador e versão → o adaptador valida a configuração (endereços só HTTPS) → criar as fontes como prova → só então gravar em `installed_extensions`.
4. **Ativar** (a cada abertura do app): o manifesto salvo é conferido pelo SHA-256 gravado, e cada extensão é ativada **isoladamente**. Uma falha marca só aquela extensão como "Falha".
5. **Atualizar** preserva o ID das fontes (`fyx:<id>/<fonte>`), então a biblioteca continua vinculada. A versão nunca regride. Atualização automática é uma preferência por extensão, desligada por padrão.
6. **Remover** apaga só o registro. Títulos, progresso e capítulos baixados continuam na biblioteca.

Sem o adaptador correspondente (ou com uma versão de adaptador desconhecida), a extensão aparece como **"Incompatível com esta versão do app"**.

### Exemplo de índice nativo

```json
{
  "format": "freeyomi.repository.v1",
  "name": "Meu repositório",
  "badgeLabel": "MEU",
  "extensions": [{
    "id": "org.exemplo.fonte", "name": "Minha fonte", "versionCode": 1, "versionName": "1.0.0",
    "language": "pt-BR", "contentWarning": "SAFE",
    "adapter": "mangadex-api-v5", "adapterVersion": 1,
    "manifestUrl": "org.exemplo.fonte.json",
    "sha256": "<sha-256 do manifesto>",
    "sources": [{"id": "pt-br", "name": "Minha fonte", "language": "pt-BR"}]
  }]
}
```

### Exemplo de manifesto

```json
{
  "format": "freeyomi.extension.v1",
  "id": "org.exemplo.fonte", "name": "Minha fonte",
  "versionCode": 1, "versionName": "1.0.0",
  "adapter": "mangadex-api-v5", "adapterVersion": 1,
  "sources": [{"id": "pt-br", "name": "Minha fonte", "language": "pt-br"}],
  "config": {
    "apiBaseUrl": "https://api.exemplo.org",
    "coversBaseUrl": "https://covers.exemplo.org",
    "reportUrl": "https://relatorio.exemplo.org/report",
    "trustedImageHost": "exemplo.org",
    "attribution": "Créditos exigidos pelos termos da API."
  }
}
```

Quem publicar um manifesto é responsável por ter permissão para usar a API configurada e por cumprir os termos dela (por exemplo, crédito e limites de requisição). O adaptador `mangadex-api-v5` já respeita 4 req/s e 40/min no endpoint de páginas.

**Para criar um novo adaptador:** implemente `SourceAdapter` em `FYSources`, registre em `AdapterRegistry.builtIn`, escreva os testes com respostas simuladas e documente as chaves de `config`. Um adaptador novo só chega aos usuários numa nova versão do app, revisada como qualquer outro código.

## 6. Segurança

| Ameaça | Controle |
|---|---|
| Esquemas perigosos | `file:`, `javascript:`, `data:`, `content:`, `ftp:` etc. recusados antes de qualquer acesso à rede (`RepositoryURL.normalize`) |
| Credenciais na URL | Recusadas (`usuario:senha@`). Nada é enviado sem criptografia |
| HTTP | Desligado por padrão. Exige ativar em *Mais › Extensões* (com alerta) e fica marcado no repositório. O ATS do iOS só permite HTTP na rede local |
| Redirecionamentos | O destino final é revalidado: HTTPS→HTTP é sempre recusado |
| Respostas grandes / "gzip bomb" | 20 MB baixados, 64 MB descomprimidos, 25 000 extensões por índice, 256 KB por manifesto |
| Tempo limite | 30 s por requisição. A validação pode ser cancelada pelo usuário (botão "Parar"), e os downloads de extensões também |
| Dados malformados | Decodificadores tolerantes por entrada e estritos na estrutura. Protobuf com limite de aninhamento e comprimentos validados |
| Integridade | SHA-256 do manifesto conferido quando o repositório publica o hash. Sem hash, a extensão fica marcada como "Sem hash publicado". O hash gravado é conferido de novo a cada ativação |
| Assinatura | O índice informa `signingKey` (impressão digital do certificado dos APKs Android), exibida ao validar. O `.jar` não é assinado; o índice do Tachiyomi não publica hash dele, e a extensão fica marcada como "Sem hash publicado". Manifestos nativos ainda não têm assinatura (ver pendências) |
| Código de terceiros | Manifestos nativos são só dados. Extensões Android (`.jar`) **são código**: rodam como bytecode interpretado na JVM do app, com o mesmo acesso que o app tem dentro da sandbox do iOS (rede e a pasta do app). Só são baixadas de repositórios que o usuário adicionou e por ação dele; a origem e a versão ficam registradas e visíveis; nada roda antes de o usuário tocar em "Instalar". É o mesmo modelo de confiança do Mihon/Tachimanga: instale apenas extensões de repositórios em que você confia |
| Logs | Erros passam por `Redactor` (sem usuário/senha/tokens nas URLs) |

## 7. Privacidade

- Repositórios, cache e extensões instaladas ficam só no aparelho (SQLite e `Application Support/FreeYomi/RepositoryCache`).
- Não há servidor do FreeYomi: nenhuma lista de repositórios, biblioteca ou histórico é enviada a lugar nenhum.
- Os únicos acessos de rede são aos repositórios que o usuário adicionou e às fontes que ele instalou. Com um servidor de extensões conectado, os repositórios são sincronizados com **o servidor do próprio usuário**.
- A interface mostra um aviso neutro de que repositórios e fontes são mantidos por terceiros. O aviso não substitui os controles técnicos acima.

## 8. Persistência (migração 2 do banco)

- `extension_repositories`: url, canonical_key (único, detecta duplicatas como `github.com/…/raw/…` × `raw.githubusercontent.com/…`), nome, selo, site, Discord, chave, formato, total de extensões, posição, HTTP permitido, datas e resultado/erro da última sincronização.
- `installed_extensions`: id, nome, repositório de origem (ou arquivo), versão, adaptador, manifesto (bytes), SHA-256, integridade conferida, atualização automática, datas e última falha.
- A lista antiga (JSON de preferências 0.3.x) é migrada uma vez (`repositoriesMigrated`).
- O cache dos índices saiu de `Caches` (que o iOS pode apagar) para `Application Support`. O cache antigo em protobuf ainda é lido.
- Remover um repositório pede confirmação e explica o que será e o que não será apagado.

## 9. Pendências e limitações conhecidas

1. **Compilação:** este incremento foi escrito num ambiente sem compilador Swift (os downloads do Swift estão bloqueados lá). Toda a sintaxe foi verificada com um parser Swift (tree-sitter), mas a checagem de tipos e os testes só rodam no CI (`core-linux` e `ios`).
2. Manifestos nativos não têm assinatura criptográfica própria. A integridade depende do SHA-256 publicado no índice, baixado por HTTPS. Assinatura Ed25519 do índice é a próxima etapa recomendada.
3. Só há um adaptador (`mangadex-api-v5`). Cada fonte nova exige um adaptador revisado e uma nova versão do app.
4. Extensões Android rodam na JVM embutida só quando o app é compilado com ela (uso pessoal, ver 4.1). Sem `jarUrl`, dependem do servidor de extensões do usuário.
5. Nenhum ícone de extensão é carregado por HTTP. Ícones fora de HTTPS mostram um marcador.
