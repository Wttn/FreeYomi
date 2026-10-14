import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.*;
import java.util.regex.*;

public class Hello {
    public static String run(String pluginJar) {
        StringBuilder sb = new StringBuilder();
        try {
            sb.append("Java ").append(System.getProperty("java.version"))
              .append(" ").append(System.getProperty("java.vm.name"))
              .append(" home=").append(System.getProperty("java.home"));
            Matcher m = Pattern.compile("(\\d+)").matcher("capitulo 1195");
            sb.append(" | regex=").append(m.find() ? m.group(1) : "?");
            Map<String, Integer> map = new TreeMap<>();
            for (String s : "b a c a".split(" ")) map.merge(s, 1, Integer::sum);
            sb.append(" | map=").append(map);
            try (URLClassLoader loader = new URLClassLoader(new URL[]{ new File(pluginJar).toURI().toURL() }, Hello.class.getClassLoader())) {
                Class<?> c = loader.loadClass("Plugin");
                sb.append(" | plugin: ").append(c.getMethod("hello").invoke(null));
            }
        } catch (Throwable t) {
            sb.append(" | ERRO ").append(t);
        }
        return sb.toString();
    }
}
