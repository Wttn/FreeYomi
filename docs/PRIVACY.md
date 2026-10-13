# Privacidade, segurança e permissões

## Dados

| Dado | Onde fica | Sai do aparelho? |
|---|---|---|
| Biblioteca, capítulos, categorias | SQLite em `Application Support/FreeYomi/` | Não |
| Histórico, progresso, tempo de leitura | SQLite | Não (o modo anônimo deixa de registrá-los) |
| Preferências | SQLite (JSON) | Não |
| Cache do catálogo de extensões | `Caches/catalog/` | Não |

Não existem conta, servidor próprio, telemetria, SDK de análise ou publicidade.

## Rede

O app só faz requisições quando:

1. o usuário abre **Explorar › Extensões** (download do índice de metadados por HTTPS);
2. o usuário navega por uma fonte online (nenhuma na Fase 1, além da demo, que é local).

Salvaguardas em `FYCore`:

- `URLPolicy.validateRemote`: só `https://`, validado também na URL final após redirecionamentos;
- limite de tamanho das respostas (32 MB) e do conteúdo descomprimido (64 MB);
- `Redactor`: remove usuário, senha e parâmetros como `token`/`api_key` de URLs antes de qualquer mensagem de erro;
- sessão `URLSession` efêmera (sem cookies persistentes nem cache HTTP).

## Código de terceiros

Nenhum. O app não baixa nem executa APK, JAR, JavaScript ou qualquer outro código. Extensões do catálogo são apenas listadas.

## Arquivos importados

- Os arquivos são tratados como não confiáveis: limites de entradas, tamanho e taxa de compressão; CRC-32 verificado; imagens validadas pelo conteúdo.
- Nenhum nome vindo do arquivo é usado como caminho de destino (as páginas são renumeradas), e nomes com `..`, caminhos absolutos ou letras de unidade são ignorados.
- As páginas ficam em `Application Support/FreeYomi/LocalFiles` e podem ser apagadas por título ("Excluir arquivos importados"). O espaço ocupado aparece em *Mais › Geral › Armazenamento*.

## Permissões do iOS

| Permissão | Solicitada? | Motivo |
|---|---|---|
| Rede | Implícita (sem diálogo no iOS) | Catálogo e fontes |
| Fotos, câmera, microfone, localização, contatos, rastreamento (ATT) | **Não** | — |
| Arquivos | Seletor do sistema (`fileImporter`) e "Abrir com FreeYomi": acesso temporário (security-scoped) só ao que o usuário escolher, liberado ao fim da cópia. O original nunca é alterado | Importar CBZ/ZIP/EPUB/pastas |
| Notificações | Futuro, opcional | Avisar capítulos novos |

`ITSAppUsesNonExemptEncryption = false`: o app usa apenas o TLS do sistema.
