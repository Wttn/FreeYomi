/*
 * FreeYomi — cria o arquivo lib/modules (formato jimage) a partir das classes
 * "explodidas" do OpenJDK Mobile (build/<conf>/jdk/modules/<módulo>).
 *
 * Por quê: arquivos .class começam com 0xCAFEBABE, o mesmo número mágico de um
 * binário Mach-O universal; ferramentas de assinatura (Sideloadly, codesign)
 * tentam assinar cada um e falham. No formato jimage as classes ficam num
 * único arquivo, como num JDK normal.
 *
 * O module-info.class de cada módulo ganha o atributo ModulePackages (como
 * faz a ferramenta jmod): sem ele, o JDK lê do jimage só os pacotes
 * exportados e a inicialização falha ("A non-java.base package was loaded
 * prior to module system initialization").
 *
 * Usa as classes de leitura/escrita de jimage do próprio OpenJDK (pacote
 * fyjimage, copiado de jdk.internal.jimage e jdk.tools.jlink.internal do
 * openjdk/mobile, GPLv2 + Classpath Exception), sem plugins do jlink.
 * Uso: java -cp out fyjimage.tool.Main <pasta modules> <saída lib/modules> [verificar-classe...]
 */
package fyjimage.tool;

import fyjimage.BasicImageWriter;
import fyjimage.ImageLocation;
import fyjimage.ImageReader;
import fyjimage.ImageResourcesTree;
import fyjimage.PreviewMode;

import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.Set;
import java.util.TreeMap;
import java.util.stream.Stream;

public class Main {
    public static void main(String[] args) throws IOException {
        Path modules = Path.of(args[0]);
        Path output = Path.of(args[1]);
        // Recurso -> arquivo, em ordem estável.
        TreeMap<String, Path> resources = new TreeMap<>();
        // module-info.class reescritos (recurso -> bytes).
        Map<String, byte[]> rewritten = new HashMap<>();
        try (Stream<Path> mods = Files.list(modules)) {
            for (Path mod : mods.sorted().toList()) {
                if (!Files.isDirectory(mod)) continue;
                String name = mod.getFileName().toString();
                TreeSet<String> packages = new TreeSet<>();
                try (Stream<Path> files = Files.walk(mod)) {
                    for (Path f : files.filter(Files::isRegularFile).toList()) {
                        String rel = mod.relativize(f).toString().replace('\\', '/');
                        resources.put("/" + name + "/" + rel, f);
                        int slash = rel.lastIndexOf('/');
                        if (slash > 0 && !rel.equals("module-info.class")) {
                            String pkg = rel.substring(0, slash);
                            if (rel.endsWith(".class") || isPackageName(pkg)) packages.add(pkg);
                        }
                    }
                }
                Path info = mod.resolve("module-info.class");
                if (!Files.isRegularFile(info)) throw new IOException("módulo sem module-info.class: " + name);
                rewritten.put("/" + name + "/module-info.class", addModulePackages(Files.readAllBytes(info), packages));
            }
        }
        Set<String> names = resources.keySet();
        BasicImageWriter writer = new BasicImageWriter(ByteOrder.LITTLE_ENDIAN); // arm64
        List<String> paths = new ArrayList<>();
        long offset = 0;
        for (var e : resources.entrySet()) {
            byte[] replaced = rewritten.get(e.getKey());
            long size = replaced != null ? replaced.length : Files.size(e.getValue());
            int flags = ImageLocation.getPreviewFlags(e.getKey(), names::contains);
            writer.addLocation(e.getKey(), offset, 0, size, flags);
            paths.add(e.getKey());
            offset += size;
        }
        ImageResourcesTree tree = new ImageResourcesTree(offset, writer, paths);
        Files.createDirectories(output.toAbsolutePath().getParent());
        try (DataOutputStream out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(output), 1 << 20))) {
            byte[] index = writer.getBytes();
            out.write(index);
            for (var e : resources.entrySet()) {
                byte[] replaced = rewritten.get(e.getKey());
                if (replaced != null) out.write(replaced); else Files.copy(e.getValue(), out);
            }
            tree.addContent(out);
        }
        System.out.println(resources.size() + " recursos, " + Files.size(output) / (1024 * 1024) + " MB -> " + output);

        // Verificação com o leitor do próprio OpenJDK.
        try (ImageReader reader = ImageReader.open(output, ByteOrder.LITTLE_ENDIAN, PreviewMode.DISABLED)) {
            for (int i = 2; i < args.length; i++) {
                String path = args[i];
                ImageReader.Node node = reader.findNode(path);
                if (node == null) throw new IOException("não encontrado no jimage: " + path);
                if (node.isResource()) {
                    byte[] bytes = reader.getResource(node);
                    String key = path.substring("/modules".length());
                    byte[] original = rewritten.containsKey(key) ? rewritten.get(key) : Files.readAllBytes(resources.get(key));
                    if (!java.util.Arrays.equals(bytes, original)) throw new IOException("conteúdo diferente: " + path);
                }
                System.out.println("ok " + path);
            }
        }
    }

    private static final java.util.Set<String> KEYWORDS = java.util.Set.of(
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "_");

    /** Pacote válido (como na ferramenta jmod: pastas de recursos como META-INF não contam). */
    static boolean isPackageName(String internal) {
        for (String part : internal.split("/")) {
            if (part.isEmpty() || KEYWORDS.contains(part) || !Character.isJavaIdentifierStart(part.charAt(0))) return false;
            for (int i = 1; i < part.length(); i++) if (!Character.isJavaIdentifierPart(part.charAt(i))) return false;
        }
        return true;
    }

    /**
     * Acrescenta o atributo ModulePackages (JVMS 4.7.26) ao module-info.class,
     * se ainda não existir. Edita o arquivo de classe diretamente: novas
     * entradas no fim do pool de constantes e um atributo a mais no fim.
     */
    static byte[] addModulePackages(byte[] classFile, java.util.Collection<String> packages) throws IOException {
        DataInputStream in = new DataInputStream(new ByteArrayInputStream(classFile));
        if (in.readInt() != 0xCAFEBABE) throw new IOException("module-info.class inválido");
        in.readUnsignedShort(); in.readUnsignedShort(); // versão
        int cpCount = in.readUnsignedShort();
        String[] utf8 = new String[cpCount];
        Map<String, Integer> utf8Index = new HashMap<>();
        Map<Integer, Integer> packageIndexByName = new HashMap<>(); // índice Utf8 -> índice Package
        for (int i = 1; i < cpCount; i++) {
            int tag = in.readUnsignedByte();
            switch (tag) {
                case 1 -> { utf8[i] = in.readUTF(); utf8Index.putIfAbsent(utf8[i], i); }
                case 7, 8, 16, 19, 20 -> {
                    int ref = in.readUnsignedShort();
                    if (tag == 20) packageIndexByName.put(ref, i);
                }
                case 3, 4 -> in.readInt();
                case 5, 6 -> { in.readLong(); i++; }
                case 9, 10, 11, 12, 17, 18 -> in.readInt();
                case 15 -> { in.readUnsignedByte(); in.readUnsignedShort(); }
                default -> throw new IOException("tag de constante desconhecida: " + tag);
            }
        }
        int cpEnd = classFile.length - in.available();
        in.readUnsignedShort(); in.readUnsignedShort(); in.readUnsignedShort(); // access, this, super
        if (in.readUnsignedShort() != 0 || in.readUnsignedShort() != 0 || in.readUnsignedShort() != 0) {
            throw new IOException("module-info.class com interfaces, campos ou métodos");
        }
        int attrCountPos = classFile.length - in.available();
        int attrCount = in.readUnsignedShort();
        for (int a = 0; a < attrCount; a++) {
            String attrName = utf8[in.readUnsignedShort()];
            int len = in.readInt();
            if ("ModulePackages".equals(attrName)) return classFile; // já tem
            in.skipNBytes(len);
        }

        // Novas constantes.
        ByteArrayOutputStream extra = new ByteArrayOutputStream();
        java.io.DataOutputStream cp = new java.io.DataOutputStream(extra);
        int[] next = {cpCount};
        java.util.function.Function<String, Integer> utf = text -> {
            Integer idx = utf8Index.get(text);
            if (idx != null) return idx;
            try { cp.writeByte(1); cp.writeUTF(text); } catch (IOException e) { throw new RuntimeException(e); }
            utf8Index.put(text, next[0]);
            return next[0]++;
        };
        int attrName = utf.apply("ModulePackages");
        List<Integer> pkgIndexes = new ArrayList<>();
        for (String pkg : packages) {
            int nameIdx = utf.apply(pkg);
            Integer existing = packageIndexByName.get(nameIdx);
            if (existing == null) {
                cp.writeByte(20); cp.writeShort(nameIdx);
                existing = next[0]++;
                packageIndexByName.put(nameIdx, existing);
            }
            pkgIndexes.add(existing);
        }
        if (next[0] > 0xFFFF) throw new IOException("pool de constantes grande demais");

        ByteArrayOutputStream result = new ByteArrayOutputStream(classFile.length + extra.size() + 64);
        java.io.DataOutputStream out = new java.io.DataOutputStream(result);
        out.write(classFile, 0, 8);
        out.writeShort(next[0]);
        out.write(classFile, 10, cpEnd - 10);
        out.write(extra.toByteArray());
        out.write(classFile, cpEnd, attrCountPos - cpEnd);
        out.writeShort(attrCount + 1);
        out.write(classFile, attrCountPos + 2, classFile.length - attrCountPos - 2);
        out.writeShort(attrName);
        out.writeInt(2 + 2 * pkgIndexes.size());
        out.writeShort(pkgIndexes.size());
        for (int idx : pkgIndexes) out.writeShort(idx);
        out.flush();
        return result.toByteArray();
    }
}
