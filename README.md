# FreeYomi

Leitor de mangás, manhwas, manhuas, webtoons e quadrinhos para **iPhone e iPad** — **gratuito, open source, sem anúncios, sem assinaturas e sem recursos bloqueados**.

Inspirado no funcionamento do [Mihon](https://github.com/mihonapp/mihon)/Tachiyomi e na experiência do Tachimanga, com identidade visual própria e interface nativa em SwiftUI com **Liquid Glass** (iOS 26+). Nenhum código, marca ou recurso visual desses projetos foi copiado.

> **Status: Fase 1 (fundação) — pré-alfa.** Veja o [relatório da Fase 1](docs/PHASE1_REPORT.md) para saber o que já funciona, o que foi testado e o que está pendente.

## Princípios

- **Gratuito por arquitetura:** não existe código de compras, assinaturas, moedas ou limites artificiais.
- **Local primeiro:** biblioteca, histórico e preferências ficam em um banco SQLite no aparelho. Não há conta nem servidor próprio.
- **Sem rastreamento:** nenhum SDK de anúncios, análise ou telemetria.
- **Seguro:** o app não baixa nem executa código de terceiros. As fontes são adaptadores Swift nativos, revisados no repositório.
- **Honesto:** o catálogo de extensões Android é exibido como tal ("Requer Android"); dados de demonstração são rotulados como "DEMO".

## O que já existe (Fase 1)

- Navegação em 5 abas (Biblioteca, Atualizações, Explorar, Histórico, Mais), tema claro/escuro/automático e Liquid Glass com fallback para iOS 17/18.
- Biblioteca em grade/lista, categorias, ordenação, busca, seleção em lote e emblema de não lidos.
- Leitor inicial: paginado D→E e E→D, paginado vertical, vertical contínuo e webtoon, com zonas de toque, barra de progresso, troca de capítulo e salvamento automático do progresso.
- Histórico com tempo de leitura, retomada, exclusão (com confirmação) e modo anônimo.
- Catálogo de extensões Keiyoushi: download por HTTPS, gzip + protobuf decodificados, cache offline e classificação de compatibilidade.
- Fonte de demonstração 100% local e fictícia.
- Persistência SQLite com migrações, chaves compostas e recuperação de arquivo corrompido.

## Estrutura

```
App/                 inicialização e composição (AppModel, abas)
DesignSystem/        tokens, Liquid Glass, capas, componentes
Features/            Library, Browse, Reader, Updates, History, Downloads, Settings, Manga
Packages/FreeYomiKit núcleo multiplataforma (compila e testa em Linux)
  FYCore             erros, gzip, protobuf, HTTP, segurança
  FYDomain           entidades e regras (Manga, Chapter, ReadingProgress, AppSettings…)
  FYData             SQLite, migrações, repositórios
  FYSources          protocolo MangaSource, fonte demo, catálogo de extensões
  FYServices         casos de uso (adicionar à biblioteca, atualizar, dados demo)
Tests/UITests        testes de interface (XCUITest)
docs/                decisões, arquitetura, compilação, instalação
project.yml          definição do projeto Xcode (XcodeGen)
```

## Desenvolvimento no Windows

O desenvolvimento diário é feito no Windows; só a compilação do app iOS exige macOS, que roda no GitHub Actions.

1. Edite no **VS Code** (extensões recomendadas em `.vscode/extensions.json`).
2. Rode os testes do núcleo localmente com **Docker Desktop** ou **WSL**:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/test-core.ps1          # offline
   powershell -ExecutionPolicy Bypass -File scripts/test-core.ps1 -Live    # inclui o índice real
   ```
3. Faça `git push`: o CI compila o app no Xcode 26, roda os testes no simulador e publica um `.ipa` sem assinatura.
4. Instale no iPhone assinando com sua conta Apple pelo Windows.

Detalhes: [docs/BUILD_WINDOWS.md](docs/BUILD_WINDOWS.md) e [docs/INSTALL_IPHONE.md](docs/INSTALL_IPHONE.md).

## Documentação

- [Decisões técnicas, riscos e limitações](docs/TECHNICAL_DECISIONS.md)
- [Mapeamento das capturas de referência](docs/SCREEN_REFERENCE_MAPPING.md)
- [Arquitetura](docs/ARCHITECTURE.md)
- [Privacidade e permissões](docs/PRIVACY.md)
- [Inventário de dependências](DEPENDENCIES.md)
- [Como contribuir](CONTRIBUTING.md)

## Aviso legal

O FreeYomi não hospeda, distribui nem embute conteúdo protegido por direitos autorais, nem inclui fontes de conteúdo não autorizadas. Use-o com conteúdo que você possui ou tem permissão para acessar.

## Licença

[Apache-2.0](LICENSE). O núcleo e o app não têm dependências externas em tempo de execução (SQLite e zlib vêm com o iOS). O projeto é distribuído como open source sob essa licença; consulte o [inventário de dependências](DEPENDENCIES.md).
