public class Plugin {
    public static String hello() {
        return "ok (" + Plugin.class.getName() + " carregada de um .jar fora do classpath)";
    }
}
