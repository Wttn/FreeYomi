# Protótipo: JVM embutida (modelo do Tachimanga)

## Como o Tachimanga roda extensões no iPhone

Ele embute uma máquina virtual Java no app e roda dentro dela um fork do
Suwayomi/Tachidesk-Server: [`tachimanga/Tachidesk-Server`](https://github.com/tachimanga/Tachidesk-Server),
MPL-2.0. Esse servidor baixa o `.jar` de cada extensão (por isso o `index.pb`
traz o campo `jarUrl` 501) e executa o código Kotlin da extensão no aparelho.
Rede, WebView, Bitmap e QuickJS passam por pontes nativas (`NativeNet`,
`WebView.createNativeWebview` etc.). A parte da máquina Java para iOS não é
pública.

## Caminho do FreeYomi

1. **JVM sem JIT para iOS:** o projeto oficial [OpenJDK Mobile](https://github.com/openjdk/mobile)
   compila `libjvm.a` estático para iOS com o interpretador **Zero**, que não
   gera código de máquina em tempo de execução. Workflow:
   `.github/workflows/jvm-ios.yml`. ✅ (com 2 ajustes no HotSpot: `patches/apply.py`)
2. **Prova de vida:** app `probe/` que inicia a JVM (`JNI_CreateJavaVM`)
   dentro do app e carrega uma classe de um `.jar` fora do classpath.
   Workflow: `.github/workflows/jvm-probe.yml`. ✅ 14/10/2026, no simulador do CI:
   `Java 28-internal OpenJDK 64-Bit Zero VM | regex=1195 | map={a=2, b=1, c=1} |
   plugin: ok (Plugin carregada de um .jar fora do classpath) | 5.38 s`
   (inclui a inicialização da JVM).
3. **Runtime das extensões:** o fork do Tachidesk-Server do Tachimanga
   (MPL-2.0) é compilado como um `.jar` único com a ponte `host/FYHost.kt`
   (workflow `jvm-runtime.yml`). Rede só por OkHttp/JSSE por enquanto (as
   pontes nativas do Tachimanga para URLSession ainda não foram feitas). ✅
   14/10/2026, no simulador: extensão real do Keiyoushi baixada do `jarUrl`:
   `init=1033ms | carregar=611ms | fonte=AnimeXNovel (pt-BR) | populares=20 em 7457ms |
   «As 100 Maldições da Casa Illeston» | …` ← **próxima etapa: 4**
4. **Ponte com o app:** listar, buscar, detalhes, capítulos e páginas via JNI
   (JSON) para um `MangaSource` em Swift; instalar a partir dos repositórios
   que o usuário adicionou.

## Como os testes rodam no CI

- O OpenJDK é compilado para **aparelho** (iphoneos). Para o simulador do Mac
  Apple Silicon, `scripts/ios_to_sim.py` só troca a plataforma gravada nos
  objetos (o código arm64 é o mesmo); a libffi do simulador é compilada do
  código-fonte (3.5.2).
- O JAVA_HOME fica em `JVMProbe.app/lib` (onde o HotSpot estático do iOS
  procura), com as classes como imagem "explodida" (`lib/modules/<módulo>`).
- O build Debug precisa de `ENABLE_DEBUG_DYLIB = NO`: a JVM procura as funções
  nativas no executável principal.
- Logs completos (saída da JVM, hs_err, log do teste) são publicados no branch
  `ci-logs` a cada execução.

## Riscos conhecidos

- **Desempenho:** o Zero é um interpretador, então as extensões vão rodar bem
  mais devagar que no Android. Inicialização e memória precisam ser medidas.
- **Licença:** o HotSpot (`libjvm`) é GPLv2. Ligado estaticamente, o app
  inteiro passa a ter obrigações da GPLv2, que é incompatível com a
  Apache-2.0 atual. Para uso pessoal (sideload) não há distribuição. Para
  publicar o .ipa, será preciso decidir a licença.
- **App Store:** baixar e executar código de extensões contraria a diretriz
  2.5.2. Na prática, a distribuição seria por sideload.
- **Segurança:** extensões rodariam com o acesso que a JVM tiver dentro do
  app. O plano é isolá-las da biblioteca e do Keychain (sem ponte para esses dados).
