using Gtk;
using GLib;
using Cairo;
using Singularity;

namespace SingularityMonitorWidget {

    public class SystemStatsProvider : Object, OverviewWidgetProvider {
        public string id           { get { return "monitor.system-stats"; } }
        public string provider_id  { get { return "dev.sinty.monitor"; } }
        public string display_name { get { return "System Stats"; } }
        public string icon_name    { get { return "utilities-system-monitor-symbolic"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[4];
                    _sizes[0] = WidgetSize(1, 1);
                    _sizes[1] = WidgetSize(1, 2);
                    _sizes[2] = WidgetSize(2, 2);
                    _sizes[3] = WidgetSize(4, 2);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;
        public Gtk.Widget create_instance(string instance_id, WidgetSize size, Variant? config) {
            return new SystemStatsInstance(size);
        }
    }

    /**
     * CPU + RAM (and battery, when present) with rolling sparkline charts -
     * mirrors the look of the sidebar status-monitor plugin. Reads /proc
     * and /sys/class/power_supply directly, no app process required.
     */
    public class SystemStatsInstance : Gtk.Box {
        private const int HISTORY = 60;
        private double[] cpu_history;
        private double[] ram_history;
        private double[] bat_history;
        private DrawingArea cpu_chart;
        private DrawingArea ram_chart;
        private DrawingArea? bat_chart = null;
        private Label cpu_lbl;
        private Label ram_lbl;
        private Label? bat_lbl = null;
        private uint timer_id = 0;
        private uint64 last_total = 0;
        private uint64 last_idle = 0;
        private string? bat_dir = null;
        private string accent_hex_cpu = "#3584e4";
        private string accent_hex_ram = "#9b59b6";
        private string accent_hex_bat = "#33b35a";

        public SystemStatsInstance(WidgetSize size) {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            add_css_class("overview-sysstats");
            margin_start = 14; margin_end = 14;
            margin_top = 12; margin_bottom = 12;
            hexpand = true; vexpand = true;

            cpu_history = new double[HISTORY];
            ram_history = new double[HISTORY];
            bat_history = new double[HISTORY];

            cpu_lbl = make_value_lbl();
            ram_lbl = make_value_lbl();
            cpu_chart = new DrawingArea();
            ram_chart = new DrawingArea();
            cpu_chart.set_draw_func((d, c, w, h) =>
                draw_chart(c, w, h, cpu_history, accent_hex_cpu));
            ram_chart.set_draw_func((d, c, w, h) =>
                draw_chart(c, w, h, ram_history, accent_hex_ram));
            append(make_row("CPU", cpu_lbl, cpu_chart));
            append(make_row("Memory", ram_lbl, ram_chart));

            bat_dir = find_battery();
            if (bat_dir != null) {
                bat_lbl = make_value_lbl();
                bat_chart = new DrawingArea();
                bat_chart.set_draw_func((d, c, w, h) =>
                    draw_chart(c, w, h, bat_history, accent_hex_bat));
                append(make_row("Battery", bat_lbl, bat_chart));
            }

            tick();
            timer_id = GLib.Timeout.add(1000, () => { tick(); return GLib.Source.CONTINUE; });
            destroy.connect(() => {
                if (timer_id != 0) { GLib.Source.remove(timer_id); timer_id = 0; }
            });
        }

        private Label make_value_lbl() {
            var l = new Label("0%");
            l.add_css_class("title-3");
            l.halign = Align.END;
            return l;
        }

        private Widget make_row(string title, Label value, DrawingArea chart) {
            var card = new Gtk.Box(Orientation.VERTICAL, 4);
            card.add_css_class("overview-sysstats-card");
            card.hexpand = true; card.vexpand = true;

            var header = new Gtk.Box(Orientation.HORIZONTAL, 6);
            header.margin_start = 12; header.margin_end = 12;
            header.margin_top = 6;
            var t = new Label(title);
            t.add_css_class("caption-heading");
            t.opacity = 0.7;
            t.halign = Align.START; t.hexpand = true;
            header.append(t);
            header.append(value);
            card.append(header);

            chart.hexpand = true; chart.vexpand = true;
            chart.set_size_request(-1, 36);
            chart.margin_bottom = 6;
            card.append(chart);
            return card;
        }

        private void tick() {
            // CPU
            double cpu = 0.0;
            try {
                string c; FileUtils.get_contents("/proc/stat", out c);
                var lines = c.split("\n");
                if (lines.length > 0 && lines[0].has_prefix("cpu ")) {
                    var parts = lines[0].split(" ");
                    uint64 total = 0, idle = 0; int idx = 0;
                    foreach (var p in parts) {
                        if (p == "" || p == "cpu") continue;
                        uint64 v = uint64.parse(p);
                        if (idx == 3) idle = v;
                        total += v;
                        idx++;
                    }
                    if (last_total > 0) {
                        uint64 dt = total - last_total;
                        uint64 di = idle  - last_idle;
                        if (dt > 0) cpu = 1.0 - (double) di / (double) dt;
                    }
                    last_total = total; last_idle = idle;
                }
            } catch (Error e) {}

            // RAM
            double ram = 0.0;
            try {
                string c; FileUtils.get_contents("/proc/meminfo", out c);
                uint64 total = 0, avail = 0;
                foreach (var line in c.split("\n")) {
                    if (line.has_prefix("MemTotal:"))     total = parse_kb(line);
                    else if (line.has_prefix("MemAvailable:")) avail = parse_kb(line);
                }
                if (total > 0) ram = 1.0 - (double) avail / (double) total;
            } catch (Error e) {}

            push(cpu_history, cpu);
            push(ram_history, ram);
            cpu_lbl.label = "%d%%".printf((int)(cpu * 100));
            ram_lbl.label = "%d%%".printf((int)(ram * 100));
            cpu_chart.queue_draw();
            ram_chart.queue_draw();

            if (bat_dir != null && bat_chart != null && bat_lbl != null) {
                try {
                    string cap;
                    if (FileUtils.get_contents(bat_dir + "/capacity", out cap)) {
                        double v = double.parse(cap.strip()) / 100.0;
                        push(bat_history, v);
                        string st = "";
                        string s;
                        if (FileUtils.get_contents(bat_dir + "/status", out s)) st = s.strip();
                        bat_lbl.label = "%d%%%s".printf((int)(v * 100),
                            (st == "Charging") ? " (charging)" : "");
                        bat_chart.queue_draw();
                    }
                } catch (Error e) {}
            }
        }

        private uint64 parse_kb(string line) {
            var parts = line.split_set(" \t:");
            foreach (var p in parts) {
                if (p == "" || !p.get_char(0).isdigit()) continue;
                return uint64.parse(p);
            }
            return 0;
        }

        private void push(double[] hist, double v) {
            for (int i = 0; i < HISTORY - 1; i++) hist[i] = hist[i + 1];
            hist[HISTORY - 1] = v.clamp(0.0, 1.0);
        }

        private string? find_battery() {
            try {
                var d = File.new_for_path("/sys/class/power_supply");
                if (!d.query_exists()) return null;
                var en = d.enumerate_children("standard::name", FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = en.next_file()) != null) {
                    string n = info.get_name();
                    if (n.has_prefix("BAT")) return "/sys/class/power_supply/" + n;
                }
            } catch (Error e) {}
            return null;
        }

        private void draw_chart(Context cr, int w, int h, double[] data, string hex) {
            Gdk.RGBA color = {};
            color.parse(hex);

            double step = (double) w / (double) (HISTORY - 1);

            // Filled area below curve.
            cr.move_to(0, h);
            for (int i = 0; i < HISTORY; i++)
                cr.line_to(i * step, h - data[i] * h);
            cr.line_to(w, h);
            cr.close_path();
            color.alpha = 0.18f;
            Gdk.cairo_set_source_rgba(cr, color);
            cr.fill();

            // Curve.
            bool first = true;
            for (int i = 0; i < HISTORY; i++) {
                double y = h - data[i] * h;
                if (first) { cr.move_to(i * step, y); first = false; }
                else cr.line_to(i * step, y);
            }
            color.alpha = 1.0f;
            Gdk.cairo_set_source_rgba(cr, color);
            cr.set_line_width(2);
            cr.stroke();
        }
    }

    [CCode (cname = "singularity_monitor_widget_new")]
    public static Object singularity_monitor_widget_new() {
        return new SystemStatsProvider();
    }
}
