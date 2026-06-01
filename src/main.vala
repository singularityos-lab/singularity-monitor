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
        var app = new MonitorApp();
        return app.run(args);
    }

}
