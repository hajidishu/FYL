import java.io.File;
import java.lang.reflect.InvocationTargetException;

/** Calls the installer's own implementation without opening its Swing UI. */
public final class FylOptiFineBridge {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Minecraft directory is required");
        try {
            Class<?> installer = Class.forName("optifine.Installer");
            installer.getMethod("doInstall", File.class).invoke(null, new File(args[0]));
        } catch (InvocationTargetException error) {
            error.getCause().printStackTrace();
            System.exit(1);
        }
    }
}
