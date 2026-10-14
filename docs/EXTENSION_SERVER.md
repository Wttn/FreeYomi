# Servidor de extensões (Suwayomi-Server)

Extensões **Android** (APK) não rodam no iPhone. Para usá-las, o FreeYomi pode se conectar a **um servidor que roda no seu computador**: o [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) (gratuito, open source, MPL-2.0). O servidor executa as extensões dos repositórios que **você** adicionou numa JVM; o iPhone só exibe e lê. É o mesmo modelo de um servidor pessoal de mídia. O app não vem com nenhum repositório. Ver `EXTENSIONS_ARCHITECTURE.md`.

Por que não rodar as extensões direto no iPhone? Elas são programas Kotlin/JVM. Baixar e executar código no iOS viola a diretriz 2.5.2 da App Store e daria a código de terceiros acesso ao app. Veja `TECHNICAL_DECISIONS.md` §4 e §12.

> Sem servidor, o app continua funcionando com arquivos locais e com extensões **nativas** (manifestos para adaptadores do próprio app) instaladas dos seus repositórios.

## 1. Instalar no Windows

1. Baixe a versão **win64** mais recente em <https://github.com/Suwayomi/Suwayomi-Server/releases/latest>. O pacote já inclui o Java.
2. Extraia e execute. Na primeira vez, o Windows pergunta sobre o firewall: permita o acesso em **redes privadas**.
3. No próprio PC, abra <http://localhost:4567> para conferir se o servidor está no ar (interface web do Suwayomi).

Também há pacotes para macOS e Linux, e uma imagem Docker. As instruções completas estão no README do Suwayomi.

## 2. Descobrir o endereço do PC

No PowerShell, rode `ipconfig` e anote o **Endereço IPv4** do adaptador Wi-Fi/Ethernet (ex.: `192.168.0.10`). O endereço do servidor será `http://192.168.0.10:4567`.

Dica: reserve esse IP no roteador (DHCP estático) para ele não mudar.

## 3. Conectar o FreeYomi

1. *Mais › Extensões › Servidor de extensões* (ou *Explorar › Extensões › Conectar servidor de extensões*).
2. Digite o endereço, deixe **Permitir HTTP (rede local)** ligado e toque em **Salvar e conectar**.
3. Na primeira conexão, o iOS pede permissão de **Rede Local**: permita.
4. Os repositórios que você adicionou no app são **enviados ao seu servidor automaticamente**. Para adicionar um, use *Explorar › Extensões › Repositórios de extensões › Adicionar repositório* (veja abaixo).
5. Em *Explorar › Extensões*, as extensões Android passam a mostrar **Instalar no servidor / Atualizar / Remover**, com o selo do repositório de origem. As fontes instaladas aparecem em *Explorar › Fontes*, agrupadas por idioma, e entram na **busca global**.

## 3.1 Repositórios de extensões

*Explorar › Extensões › Repositórios de extensões* (ou *Mais › Extensões*):

- **Adicionar repositório:** cole o endereço do índice (`index.min.json`, `repo.json`, `index.json`, `index.pb` ou um índice do FreeYomi) e toque em **Validar**. O app baixa o índice e mostra nome, selo, formato, quantidade de extensões (compatíveis com iOS e Android) e a chave de assinatura. Só depois disso o botão **Adicionar** é liberado.
- O app **não sugere** repositórios. Use apenas endereços em que você confia.
- Cada repositório tem **Atualizar**, **Copiar**, estado da última sincronização e menu **⋯** (remover). Use **Editar** para reordenar.
- Links "adicionar repositório" de sites (`tachiyomi://add-repo?url=…`, `mihon://extension-store?url=…`, `freeyomi://add-repo?url=…`) abrem a tela de confirmação. Nada é adicionado sem você tocar em **Adicionar**.
- Com o servidor conectado, a lista do app e a do servidor ficam iguais: adicionar ou remover no app também adiciona ou remove no servidor, e repositórios adicionados pela interface web do Suwayomi aparecem no app.

## 4. Segurança

- **Na rede de casa**, o modo sem autenticação funciona, mas qualquer aparelho da rede pode usar o servidor. Para restringir o acesso, ative `server.authMode = "basic_auth"` com usuário e senha no `server.conf` do Suwayomi (ver *Configuring Suwayomi-Server* na wiki dele) e informe as mesmas credenciais no FreeYomi.
- A senha fica no **Keychain** do iPhone (só neste aparelho) e nunca vai para o banco, os logs ou os backups.
- O FreeYomi só aceita HTTP para o servidor configurado (mesmo host e porta). Qualquer outro destino continua exigindo HTTPS.
- **Fora de casa**: não exponha a porta 4567 na internet. Use uma VPN (ex.: Tailscale/WireGuard) ou um proxy reverso com HTTPS. Com HTTPS, desative "Permitir HTTP".
- O Basic Auth envia a senha em texto claro em HTTP. A própria documentação do Suwayomi recomenda HTTPS fora da rede local.

## 5. O que funciona via servidor

| Recurso | Situação |
|---|---|
| Listar, instalar, atualizar e remover extensões | ✅ |
| Populares, recentes e busca por fonte | ✅ |
| Detalhes, capítulos e páginas (leitura online) | ✅ (imagens com cache, zoom, progresso) |
| Busca global entre fontes | ✅ |
| Migrar títulos entre fontes | ✅ |
| Filtros avançados de busca e preferências de cada fonte | ⏳ Próximo incremento |
| Login em sites que exigem conta ou Cloudflare | Depende do servidor (WebView do Suwayomi) |

## Endpoints usados

Conferidos no código do Suwayomi-Server (commit `635751a`, 13/10/2026): `GET /api/v1/settings/about`, `/extension/list|install|update|uninstall/{pkg}`, `/source/list`, `/source/{id}/popular|latest/{page}`, `/source/{id}/search?searchTerm=&pageNum=`, `/manga/{id}?onlineFetch=`, `/manga/{id}/chapters?onlineFetch=`, `/manga/{id}/chapter/{index}`, `/manga/{id}/chapter/{index}/page/{n}`, `/manga/{id}/thumbnail` e `POST /api/graphql` (`extensionStores`, `addExtensionStore`, `removeExtensionStore`, `extensions { pkgName storeIndexUrl }` — `graphql/queries/ExtensionStoreQuery.kt` e `graphql/mutations/ExtensionStoreMutation.kt`).
