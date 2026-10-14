# Gerador de `lib/modules` (jimage)

Converte as classes "explodidas" do OpenJDK Mobile (`jdk/modules/<módulo>/**.class`) em um único arquivo `lib/modules`, no formato jimage que o HotSpot lê.

**Motivo:** um `.class` começa com `0xCAFEBABE`, o mesmo número mágico de um binário Mach-O universal. Ferramentas de assinatura (Sideloadly, AltStore, `codesign`) tentam assinar cada um e falham com "macho sign/edit failed". No formato jimage elas ficam num arquivo só, como num JDK normal.

- `src/fyjimage/` (exceto `tool/`) são cópias de `jdk.internal.jimage` e de `jdk.tools.jlink.internal` (`BasicImageWriter`, `ImageLocationWriter`, `ImageStringsWriter`, `PerfectHashBuilder`, `ImageResourcesTree`) do `openjdk/mobile` (commit `c1ed06aa`), renomeadas para o pacote `fyjimage`. Licença: GPLv2 + Classpath Exception (cabeçalhos preservados). Usar as fontes da mesma versão importa: o formato do JDK 28 é o 1.1, e o `jlink` de um JDK 21 gera 1.0.
- `src/fyjimage/tool/Main.java` monta o arquivo sem plugins do jlink e confere o resultado com o leitor do próprio OpenJDK.

Usado por `scripts/prepare-jvm.sh`.
