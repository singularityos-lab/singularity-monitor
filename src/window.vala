using Gtk;
using GLib;
using Cairo;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // ── Main app ────────────────────────────────────────────────────────────

    [GtkTemplate(ui = "/dev/sinty/monitor/ui/main.ui")]
    public class MonitorWindow : Singularity.Widgets.Window {
        [GtkChild] public unowned Box            main_hbox;
        [GtkChild] public unowned ScrolledWindow left_scroll;
        [GtkChild] public unowned Separator      main_sep;
        [GtkChild] public unowned Box            right_host;

        public MonitorWindow(Gtk.Application app) {
            Object(application: app);
            set_title("System Monitor");
            set_default_size(1100, 640);
        }
    }

}
