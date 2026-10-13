# Relatório da Fase 2 — Biblioteca e leitor

Data: 13/10/2026 · Versão: 0.2.0 (2)

## Resumo

| Item | Situação |
|---|---|
| Núcleo: leitor de ZIP seguro, importador CBZ/ZIP/EPUB/pastas, fonte "Arquivos locais", cache em disco | ✅ **57/57 testes passando** no Linux (Swift 6.0.3), incluindo o teste ao vivo do índice. Eram 38 na Fase 1; 19 são novos |
| App: importação (seletor + "Abrir com"), pipeline de imagens, zoom, escalas, posição vertical, brilho, armazenamento | ⚠️ Escrito e com sintaxe validada; **aguardando o CI no Xcode 26** |
| Testes de interface novos (importação, zoom, progresso, memória no webtoon) | ⏳ Rodam no CI |

## Funcionalidades concluídas

**Importação de conteúdo local**
- CBZ e ZIP: páginas em ordem natural (`p2` antes de `p10`); `ComicInfo.xml` (série, número, autor, resumo); volumes com pastas de capítulos viram vários capítulos.
- EPUB de imagens: ordem do *spine*, `<img>` e `<image xlink:href>`; EPUB de texto é recusado com mensagem clara.
- Pastas pelo seletor do iOS: pasta de imagens, pasta de subpastas e pasta de CBZs.
- "Abrir com FreeYomi" a partir de outros apps (tipo CBZ declarado; ZIP/EPUB como alternativos).
- Segurança: limites contra *zip bombs*, CRC-32, imagens validadas pelo conteúdo, nomes inseguros ignorados e relatados, nenhum nome do arquivo usado como destino. Uma falha não deixa lixo, e reimportar o mesmo arquivo não duplica.
- Relatório ao fim da importação: importados, duplicados, falhas por arquivo e arquivos ignorados.
- Excluir arquivos importados por título; espaço ocupado e limpeza do cache em *Mais › Geral*.

**Leitor**
- Zoom por pinça e toque duplo (`UIScrollView` nativo) nos modos paginados; sem zoom, o deslize de página continua funcionando, e com zoom as zonas de toque ficam desativadas.
- Escalas: página inteira, ajuste à largura, ajuste à altura e original (menu do leitor e Configurações).
- Pipeline de imagens: decodificação reduzida com ImageIO (inclusive faixas longas de webtoon, reduzidas pela largura), `NSCache` limitado e esvaziado em alerta de memória, cache em disco LRU para imagens remotas, pré-carga de N páginas (configurável, 0–10) cancelada ao sair, imagens liberadas fora da tela.
- Páginas corrompidas ou ausentes mostram erro com "Tentar novamente", sem derrubar o leitor.
- Posição salva nos modos verticais: página + deslocamento dentro dela, 1 s após parar de rolar, ao trocar de capítulo, ao sair e ao ir para segundo plano (recuperação após encerramento inesperado). Restauração com layout estável, usando as proporções lidas do cabeçalho das imagens.
- Brilho próprio no leitor, com restauração ao sair.

## Critérios de aceitação afetados

| # | Critério | Situação |
|---|---|---|
| 3 | Importar arquivo local compatível | ✅ Núcleo (`testImportCBZWithComicInfoAndNaturalOrder` e mais 7 testes); 🟡 interface aguardando o CI (`testImportedArchiveOpensWithZoomAndPaging`) |
| 4 | Abrir título e navegar | 🟡 Agora também com arquivos locais (teste de interface novo) |
| 5 | Progresso salvo e restaurado | ✅ Núcleo; 🟡 `testProgressIsRestored` no simulador |
| 6 | Modos horizontal e vertical | 🟡 `testWebtoonScrollingMemory` (inclui página dupla e faixa de 9000 px) |
| 9 | Leitura offline | 🟡 Arquivos locais já são 100% offline; downloads de fontes online ficam para a Fase 4 |

## Testes novos (núcleo)

- `ZipTests` (6): ida e volta stored/deflate, nomes perigosos, CRC corrompido, arquivo lixo/truncado, limites contra bomba, tamanho descomprimido divergente.
- `FileUtilitiesTests` (4): ordem natural, número no nome, detecção de imagem pelo conteúdo, cache em disco LRU.
- `LocalImportTests` (8): CBZ com ComicInfo e zip slip, volume com pastas, pasta de CBZs e imagens, EPUB pela ordem do *spine*, EPUB de texto recusado, duplicatas, RAR e arquivo vazio, `LocalSource` e exclusão.
- `LocalImportServiceTests` (1): importação em lote com sucesso, duplicata e falha; exclusão completa.

Log: `docs/test-results/phase2-core-linux.txt`.

## Correção após o primeiro CI da Fase 2

O app compilou no Xcode 26.6 e 7 dos 8 testes de interface passaram. `testWebtoonScrollingMemory` revelou um **travamento real**: ao rolar até o fim de um capítulo no modo webtoon, a thread principal deixava de responder. Causa provável: a página trocava de altura ao descarregar a imagem fora da tela (o espaço reservado tinha uma proporção um pouco diferente da imagem decodificada), entrando num ciclo de aparecer/desaparecer na borda da área visível. Correção: a altura de cada página passou a ser fixada pela proporção lida do arquivo, antes e depois de carregar; as imagens não são mais descartadas manualmente ao sair da tela (a lista preguiçosa e o `NSCache` cuidam disso); e o espaço reservado não tem animação infinita. O teste agora também verifica que o app continua respondendo após rolar até o fim.

### Segunda tentativa

A correção acima não bastou: o travamento continuou, agora no 7º deslize, de novo ao chegar ao fim do capítulo. Em vez de mais um remendo, os modos verticais foram reescritos em UIKit (`Features/Reader/VerticalPagesView.swift`): um `UIScrollView` com as páginas posicionadas pela proporção conhecida, carregamento de ±2 páginas ao redor da visível, descarte explícito das distantes e nenhum rastreamento de geometria do SwiftUI. Consequências positivas: **zoom (pinça e toque duplo) também nos modos verticais** e **restauração exata** da posição. As páginas de demonstração passaram a ser rasterizadas (`ImageRenderer`) para usar o mesmo caminho. O teste de webtoon agora também faz zoom no modo vertical.

## Pendências e problemas conhecidos

1. **Compilação do app no Xcode ainda não confirmada** para o código novo; corrijo o que o CI apontar.
2. ~~Zoom nos modos verticais~~ e ~~restauração aproximada~~: resolvidos com o leitor vertical em UIKit.
3. Imagens remotas de proporção desconhecida ajustam o layout ao carregar (preservando a posição); só se aplica a fontes online (Fase 3).
4. CBR/RAR e CB7 não são suportados (licença do UnRAR); o app orienta a converter para CBZ.
5. Orientação de tela travada por leitor e configurações por título: Fase 5.
6. O tempo de importação de arquivos grandes acontece com indicador, mas sem barra de progresso por página.

## Próximas tarefas recomendadas

1. Push → CI verde → testar no iPhone: importar um CBZ seu pelo app Arquivos, ler em paginado e webtoon, fechar o app pelo seletor e reabrir.
2. **Fase 3 (fontes):** gerenciamento de fontes mais completo, adaptador **Komga** (servidor pessoal; credenciais no Keychain, nunca em logs ou backups), migração entre fontes e avaliação de uma fonte online autorizada.
