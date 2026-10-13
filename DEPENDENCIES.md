# Inventário de dependências

Atualizado na Fase 1. **Toda nova dependência precisa ser listada aqui, com a licença verificada, no mesmo PR que a adiciona.**

## Em tempo de execução (vão para o app)

| Componente | Origem | Licença | Uso |
|---|---|---|---|
| SQLite (`libsqlite3`) | Biblioteca do sistema iOS (Linux: `libsqlite3-dev`) | Domínio público | Banco local |
| zlib (`libz`) | Biblioteca do sistema iOS (Linux: `zlib1g-dev`) | Licença zlib | Descompressão gzip do índice de extensões |
| SwiftUI, Foundation, Observation, UIKit, ImageIO, UniformTypeIdentifiers | SDK da Apple | Termos do SDK da Apple (frameworks do sistema, não redistribuídos) | Interface e sistema |

Nenhum pacote Swift, CocoaPod ou binário de terceiros é incluído.

## Somente para desenvolvimento/CI (não vão para o app)

| Ferramenta | Licença | Uso |
|---|---|---|
| XcodeGen | MIT | Gera o `.xcodeproj` a partir de `project.yml` |
| Imagem Docker `swift:6.1-noble` | Apache-2.0 (toolchain Swift) | Testes do núcleo em Linux/Windows |
| GitHub Actions `actions/checkout`, `actions/upload-artifact` | MIT | CI |
| XCTest | Apple / Apache-2.0 (corelibs no Linux) | Testes |

## Serviços externos opcionais (não embutidos)

| Serviço | Licença / termos | Uso |
|---|---|---|
| Suwayomi-Server (instalado pelo usuário no próprio computador) | MPL-2.0 | Executa as extensões; o FreeYomi é só um cliente da API. Nenhum código do Suwayomi é incluído no app |
| Adaptador `mangadex-api-v5` | Código próprio (Apache-2.0). Nenhum endereço embutido; quem publica o manifesto é responsável pelos termos da API configurada | Só funciona com um manifesto instalado pelo usuário |

## Dados de terceiros

| Dado | Licença | Uso |
|---|---|---|
| Formatos de índice de repositório (Mihon) | Apache-2.0 (referência de interoperabilidade; nenhum código copiado) | Os repositórios são informados pelo usuário. Uma amostra de metadados públicos (10 extensões) é usada só como fixture de teste em `Packages/FreeYomiKit/Tests/FYSourcesTests/Fixtures/` e não entra no app |

## Referências consultadas (sem código copiado)

| Projeto | Licença | Observação |
|---|---|---|
| Mihon | Apache-2.0 | Esquema do índice (números de campo) e conceitos funcionais |
| Tachimanga | Sem licença publicada | Apenas a experiência observável nas capturas; nada reutilizado |

## Classificação

Todos os componentes acima são compatíveis com a Apache-2.0. Não há dependências que impeçam classificar o FreeYomi como open source.
