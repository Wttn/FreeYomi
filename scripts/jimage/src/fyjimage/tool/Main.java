/*
 * FreeYomi — cria o arquivo lib/modules (formato jimage) a partir das classes
 * "explodidas" do OpenJDK Mobile (build/<conf>/jdk/modules/<módulo>).
 *
 * Por quê: arquivos .class começam com 0xCAFEBABE, o mesmo número mágico de um
 * binário Mach-O universal; ferramentas de assinatura (Sideloadly, codesign)
 * tentam assinar cada um e falham. No formato jimage as classes ficam num
 * único arquivo, como num JDK normal.
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
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeMap;
import java.util.stream.Stream;

public class Main {
    public static void main(String[] args) throws IOException {
        Path modules = Path.of(args[0]);
        Path output = Path.of(args[1]);
        // Recurso -> arquivo, em ordem estável.
        TreeMap<String, Path> resources = new TreeMap<>();
        try (Stream<Path> mods = Files.list(modules)) {
            for (Path mod : mods.sorted().toList()) {
                if (!Files.isDirectory(mod)) continue;
                String name = mod.getFileName().toString();
                try (Stream<Path> files = Files.walk(mod)) {
                    for (Path f : files.filter(Files::isRegularFile).toList()) {
                        String rel = mod.relativize(f).toString().replace('\\', '/');
                        resources.put("/" + name + "/" + rel, f);
                    }
                }
            }
        }
        Set<String> names = resources.keySet();
        BasicImageWriter writer = new BasicImageWriter(ByteOrder.LITTLE_ENDIAN); // arm64
        List<String> paths = new ArrayList<>();
        long offset = 0;
        for (var e : resources.entrySet()) {
            long size = Files.size(e.getValue());
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
            for (Path f : resources.values()) Files.copy(f, out);
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
                    byte[] original = Files.readAllBytes(resources.get(path.substring("/modules".length())));
                    if (!java.util.Arrays.equals(bytes, original)) throw new IOException("conteúdo diferente: " + path);
                }
                System.out.println("ok " + path);
            }
        }
    }
}
