#!/usr/bin/env bash
# Prepara a JVM embutida para compilar o FreeYomi (macOS, usado pelo CI).
#
# Entradas (artefatos dos workflows "Protótipo JVM iOS" e "runtime das extensões"):
#   $JVM_ARTIFACTS     pasta com openjdk-iphoneos-zero/*.tgz  (OpenJDK Mobile, Zero, estático)
#   $RUNTIME_ARTIFACTS pasta com fy-runtime/fy-runtime.jar    (fork do Tachidesk-Server + FYHost)
#   $JAVA_HOME         um JDK do runner (certificados, política de criptografia, fusos)
#   $TEST_REPO_INDEX   opcional: índice de onde baixar UMA extensão para o teste do CI
#
# Saída em JVM/build/ (não versionada):
#   JVM.xcconfig             incluído por Config/FreeYomi.xcconfig (liga a JVM, FY_JVM=1)
#   include/                 cabeçalhos JNI
#   libs/<sdk>/              bibliotecas estáticas (aparelho e simulador Apple Silicon) + libffi
#   bundle/lib, bundle/jars  copiados para FreeYomi.app/lib e FreeYomi.app/jars
#
# Se algo faltar, o script avisa e sai sem gerar o JVM.xcconfig: o app compila sem a JVM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/JVM/build"
WORK="$ROOT/JVM/work"
trap 'echo "::error title=JVM (linha $LINENO)::$BASH_COMMAND"; rm -f "$OUT/JVM.xcconfig"' ERR

rm -rf "$OUT"
mkdir -p "$OUT/bundle/lib" "$OUT/bundle/jars" "$OUT/libs/iphoneos" "$OUT/libs/iphonesimulator" "$WORK"

TGZ=$(find "${JVM_ARTIFACTS:-/nonexistent}" -path '*openjdk-iphoneos-zero*' -name '*.tgz' 2>/dev/null | head -1 || true)
RT=$(find "${RUNTIME_ARTIFACTS:-/nonexistent}" -name 'fy-runtime.jar' 2>/dev/null | head -1 || true)
if [ -z "$TGZ" ] || [ -z "$RT" ]; then
  echo "::warning title=JVM::artefatos da JVM não encontrados (openjdk: ${TGZ:-nenhum}, runtime: ${RT:-nenhum}); app sem runtime de extensões"
  exit 0
fi

# 1. OpenJDK Mobile (aparelho)
DEV="$WORK/iphoneos"
rm -rf "$DEV" && mkdir -p "$DEV" && tar -xzf "$TGZ" -C "$DEV"
LIBDIR="$DEV/static-libs/lib"
for l in zero/libjvm.a libjava.a libjimage.a libnet.a libnio.a libzip.a; do
  [ -f "$LIBDIR/$l" ] || { echo "::warning title=JVM::falta $l no artefato"; exit 0; }
  cp "$LIBDIR/$l" "$OUT/libs/iphoneos/$(basename "$l")"
  # Simulador (Apple Silicon): o mesmo código, marcado como simulador.
  python3 "$ROOT/scripts/ios_to_sim.py" "$LIBDIR/$l" "$OUT/libs/iphonesimulator/$(basename "$l")" > /dev/null
done

# 2. Cabeçalhos JNI
cp -R "$DEV/include" "$OUT/include"
if [ -z "$(find "$OUT/include" -name jni_md.h)" ]; then
  printf '%s\n' '#ifndef _JAVASOFT_JNI_MD_H_' '#define _JAVASOFT_JNI_MD_H_' \
    '#define JNIEXPORT __attribute__((visibility("default")))' '#define JNIIMPORT __attribute__((visibility("default")))' \
    '#define JNICALL' 'typedef int jint;' '#ifdef _LP64' 'typedef long jlong;' '#else' 'typedef long long jlong;' '#endif' \
    'typedef signed char jbyte;' '#endif' > "$OUT/include/jni_md.h"
fi

# 3. JAVA_HOME (classes em imagem explodida) + segurança do JDK do runner
cp -R "$DEV/javahome/." "$OUT/bundle/lib/"
[ -d "$OUT/bundle/lib/modules/java.base" ] || { echo "::warning title=JVM::artefato sem classes do Java"; exit 0; }
mkdir -p "$OUT/bundle/lib/conf/security" "$OUT/bundle/lib/lib/security"
cp -R "$JAVA_HOME/conf/security/." "$OUT/bundle/lib/conf/security/"
cp "$JAVA_HOME/lib/security/cacerts" "$OUT/bundle/lib/lib/security/"
cp "$JAVA_HOME/lib/security/default.policy" "$OUT/bundle/lib/lib/security/" 2>/dev/null || true
cp "$JAVA_HOME/lib/tzdb.dat" "$OUT/bundle/lib/lib/" 2>/dev/null || true

# 4. Runtime das extensões
cp "$RT" "$OUT/bundle/jars/fy-runtime.jar"

# 5. libffi: a do pacote de apoio do OpenJDK Mobile (aparelho) e 3.5.2 compilada para o simulador
if [ ! -f "$WORK/support.zip" ]; then
  curl -fsSL "${SUPPORT_ZIP:-https://download2.gluonhq.com/mobile/mobile-support-20250106.zip}" -o "$WORK/support.zip"
fi
rm -rf "$WORK/support" && unzip -q "$WORK/support.zip" -d "$WORK/support"
cp "$(find "$WORK/support" -path '*libffi*' -name 'libffi.a' | sed -n 1p)" "$OUT/libs/iphoneos/libffi.a"
if [ ! -f "$WORK/libffi-sim.a" ]; then
  curl -fsSL https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz -o "$WORK/libffi.tgz"
  rm -rf "$WORK/libffi-3.5.2" && tar -xzf "$WORK/libffi.tgz" -C "$WORK"
  SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
  (cd "$WORK/libffi-3.5.2" && ./configure --build=x86_64-apple-darwin --host=aarch64-apple-darwin \
      --disable-shared --enable-static --disable-docs \
      CC="$(xcrun -f clang) -target arm64-apple-ios17.0-simulator -isysroot $SDK" > ../ffi-configure.log 2>&1 \
    && make -j4 > ../ffi-make.log 2>&1) || { tail -20 "$WORK/ffi-configure.log" "$WORK/ffi-make.log"; false; }
  cp "$(find "$WORK/libffi-3.5.2" -name libffi.a -path '*/.libs/*' | sed -n 1p)" "$WORK/libffi-sim.a"
fi
cp "$WORK/libffi-sim.a" "$OUT/libs/iphonesimulator/libffi.a"

# 6. Configuração de compilação
LIBS='$(FY_JVM_LIBS)'
{
  echo "// Gerado por scripts/prepare-jvm.sh — não editar."
  echo "FY_JVM_LIBS[sdk=iphoneos*] = \$(SRCROOT)/JVM/build/libs/iphoneos"
  echo "FY_JVM_LIBS[sdk=iphonesimulator*] = \$(SRCROOT)/JVM/build/libs/iphonesimulator"
  echo "GCC_PREPROCESSOR_DEFINITIONS = \$(inherited) FY_JVM=1"
  echo "HEADER_SEARCH_PATHS = \$(inherited) \$(SRCROOT)/JVM/build/include/**"
  echo "LIBRARY_SEARCH_PATHS = \$(inherited) $LIBS"
  # -force_load: os JNI_OnLoad_* e Java_* das bibliotecas são procurados por nome em tempo de execução.
  echo "OTHER_LDFLAGS = \$(inherited) -force_load $LIBS/libjvm.a -force_load $LIBS/libjava.a -force_load $LIBS/libjimage.a -force_load $LIBS/libnet.a -force_load $LIBS/libnio.a -force_load $LIBS/libzip.a -lffi -lz -lc++ -framework CoreFoundation -framework Security -framework CFNetwork -framework SystemConfiguration"
  echo "DEAD_CODE_STRIPPING = NO"
  echo "STRIP_STYLE = debugging"
} > "$OUT/JVM.xcconfig"

echo "::notice title=JVM::embutida — runtime $(du -h "$OUT/bundle/jars/fy-runtime.jar" | cut -f1), JAVA_HOME $(du -sh "$OUT/bundle/lib" | cut -f1), $(ls "$OUT/bundle/lib/modules" | wc -l | tr -d ' ') módulos"

# 7. Extensão de teste (só para o teste do CI; não entra no app)
if [ -n "${TEST_REPO_INDEX:-}" ]; then
  mkdir -p "$ROOT/Tests/AppTests/Fixtures"
  python3 "$ROOT/scripts/pick_test_extension.py" "$TEST_REPO_INDEX" "$ROOT/Tests/AppTests/Fixtures" \
    | sed 's/^/::notice title=extensão de teste::/' || echo "::warning title=extensão de teste::não baixada"
fi
