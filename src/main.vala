using Gtk;
using GLib;
using Cairo;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // Delegate for ColumnView cell widget factories
    public delegate Widget ProcColFactory(Object item);
    public delegate string StrExtractor(Object item);

    public static int main(string[] args) {
        Intl.setlocale(GLib.LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = GLib.FileUtils.read_link("/proc/self/exe");
            locale_dir = GLib.Path.build_filename(GLib.Path.get_dirname(GLib.Path.get_dirname(exe)), "share", "locale");
        } catch (GLib.Error e) { }
        Intl.bindtextdomain("singularity-monitor", locale_dir);
        Intl.bind_textdomain_codeset("singularity-monitor", "UTF-8");
        Intl.textdomain("singularity-monitor");

        var app = new MonitorApp();
        return app.run(args);
    }

}
