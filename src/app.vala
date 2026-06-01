using Gtk;
using GLib;
using Cairo;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // ── Resource stat card ──────────────────────────────────────────────────

    private Box make_stat_card(string title, string icon_name,
                                SparkLine chart, Label value_lbl,
                                Label? sub_lbl = null) {
        var card = new Box(Orientation.VERTICAL, 0);
        card.add_css_class("monitor-card");

        var hdr = new Box(Orientation.HORIZONTAL, 6);
        hdr.margin_top    = 12;
        hdr.margin_start  = 14;
        hdr.margin_end    = 14;
        hdr.margin_bottom = 4;

        var icon = new Image.from_icon_name(icon_name);
        icon.pixel_size = 16;
        icon.opacity    = 0.7;
        hdr.append(icon);

        var ttl = new Label(title);
        ttl.add_css_class("monitor-card-title");
        ttl.hexpand  = true;
        ttl.halign   = Align.START;
        hdr.append(ttl);

        value_lbl.add_css_class("monitor-card-value");
        hdr.append(value_lbl);

        card.append(hdr);

        if (sub_lbl != null) {
            sub_lbl.add_css_class("monitor-card-sub");
            sub_lbl.halign       = Align.START;
            sub_lbl.margin_start = 14;
            sub_lbl.margin_bottom = 2;
            card.append(sub_lbl);
        }

        var chart_wrap = new Box(Orientation.VERTICAL, 0);
        chart_wrap.add_css_class("monitor-chart-wrap");
        chart_wrap.vexpand = true;
        chart.margin_top    = 4;
        chart.margin_bottom = 8;
        chart.margin_start  = 14;
        chart.margin_end    = 14;
        chart.set_size_request(-1, 60);
        chart_wrap.append(chart);
        card.append(chart_wrap);

        return card;
    }

    [DBus (name = "dev.sinty.Dock")]
    private interface DockSurface : Object {
        public abstract void SetSuffix(string app_id, Variant widgets) throws GLib.Error;
        public abstract void ClearSuffix(string app_id) throws GLib.Error;
    }

    public class MonitorApp : Singularity.Application {

        public MonitorApp() {
            Object(application_id: "dev.sinty.monitor",
                   flags: ApplicationFlags.FLAGS_NONE);
        }

        private DockSurface? _dock = null;
        private double _last_cpu_pct = 0;
        private double _last_mem_pct = 0;

        private MonitorWindow main_window;

        // ── Timers ──────────────────────────────────────────────────────────
        private uint _resource_timer  = 0;
        private uint _process_timer   = 0;
        private const int _process_interval_sec = 5;
        private uint _proc_refresh_id = 0;
        private bool _menu_open       = false;
        private bool _pending_refresh = false;

        // ── CPU ─────────────────────────────────────────────────────────────
        private ulong   cpu_last_total = 0;
        private ulong   cpu_last_idle  = 0;
        private ulong[] core_last_total;
        private ulong[] core_last_idle;
        private int     num_cores = 0;
        private SparkLine  cpu_spark;
        private Label      cpu_value_lbl;
        private Label      cpu_sub_lbl;
        private Box        core_bars_box;
        private MiniBar[]  core_bars;

        // ── Memory ──────────────────────────────────────────────────────────
        private SparkLine mem_spark;
        private Label     mem_value_lbl;
        private Label     mem_sub_lbl;

        // ── Disk ────────────────────────────────────────────────────────────
        private ulong   disk_last_read  = 0;
        private ulong   disk_last_write = 0;
        private SparkLine disk_read_spark;
        private SparkLine disk_write_spark;
        private Label     disk_value_lbl;
        private Label     disk_sub_lbl;

        // ── Disk I/O tab ────────────────────────────────────────────────────
        private SparkLine disk_tab_read_spark;
        private SparkLine disk_tab_write_spark;
        private Label     disk_tab_read_lbl;
        private Label     disk_tab_write_lbl;
        private Label     disk_tab_total_lbl;
        private ulong     disk_total_read_kb  = 0;
        private ulong     disk_total_write_kb = 0;

        // ── Network ─────────────────────────────────────────────────────────
        private ulong   net_last_rx = 0;
        private ulong   net_last_tx = 0;
        private SparkLine net_rx_spark;
        private SparkLine net_tx_spark;
        private Label     net_value_lbl;
        private Label     net_sub_lbl;

        // ── Network tab ─────────────────────────────────────────────────────
        private SparkLine net_tab_rx_spark;
        private SparkLine net_tab_tx_spark;
        private Label     net_tab_rx_lbl;
        private Label     net_tab_tx_lbl;
        private Label     net_tab_total_lbl;
        private ulong     net_total_rx_kb = 0;
        private ulong     net_total_tx_kb = 0;

        // ── Processes ───────────────────────────────────────────────────────
        private GLib.ListStore     proc_store;
        private ProcessListModel   _proc_list_model;
        private SortListModel      proc_sort_model;
        private ColumnView         proc_view;
        private SingleSelection     _proc_sel;
        private string _proc_search_text = "";

        // ── Search (toolbar stack, same pattern as Files) ────────────────────
        private Stack  toolbar_stack;
        private Singularity.Widgets.SearchBubble _search_bubble;
        private Gtk.SearchEntry  search_entry_widget;

        // ── Processes state ──────────────────────────────────────────────────
        private HashTable<int, ProcessInfo> prev_procs;

        protected override void startup() {
            base.startup();

            var menu = new GLib.Menu();
            var file_menu = new GLib.Menu();
            file_menu.append("Settings", "app.settings");
            file_menu.append("Quit", "app.quit");
            menu.append_submenu("File", file_menu);
            set_menubar(menu);

            var act_settings = new SimpleAction("settings", null);
            act_settings.activate.connect(() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync(
                        BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings("dev.sinty.monitor");
                } catch (Error e) {
                    warning("Failed to open settings: %s", e.message);
                }
            });
            add_action(act_settings);

            var act_quit = new SimpleAction("quit", null);
            act_quit.activate.connect(() => quit());
            add_action(act_quit);
        }

        protected override void activate() {
            setup_styles();
            main_window = new MonitorWindow(this);

            num_cores       = count_cores();
            core_last_total = new ulong[num_cores];
            core_last_idle  = new ulong[num_cores];
            core_bars       = new MiniBar[num_cores];

            // Bubble bar: always-visible SearchBubble (Store pattern,
            // no toggle icon).
            var search_bubble = main_window.add_bubble_search ("Filter processes...", (t) => {
                _proc_list_model.search = t.strip ().down ();
                refresh_processes ();
            });
            search_entry_widget = search_bubble.entry;

            var key_ctrl = new EventControllerKey ();
            key_ctrl.key_pressed.connect ((kv, kc, mstate) => {
                if (kv == Gdk.Key.Escape) {
                    close_search ();
                    return true;
                }
                return false;
            });
            search_entry_widget.add_controller (key_ctrl);
            toolbar_stack = null;
            _search_bubble = search_bubble;

            // Left panel - resource cards. Moved out of main_hbox into
            // the Window's sidebar slot so it behaves like every other
            // app sidebar (10px padding from .window-sidebar, no bubble
            // bar overlay, no extra apply_titlebar_inset reserve).
            main_window.left_scroll.hscrollbar_policy = PolicyType.NEVER;
            main_window.left_scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            main_window.left_scroll.hexpand = false;
            main_window.left_scroll.propagate_natural_width = false;
            main_window.left_scroll.set_child(build_resources_column());
            main_window.main_hbox.remove(main_window.left_scroll);
            main_window.main_hbox.remove(main_window.main_sep);
            main_window.set_sidebar(main_window.left_scroll);
            main_window.set_sidebar_width(320);
            main_window.set_sidebar_visible(true);

            // Right panel - process list
            var right_box = build_processes_panel();
            main_window.right_host.append(right_box);

            main_window.set_content(main_window.main_hbox);

            // Window-level key handler: printable char, open search
            var win_key = new EventControllerKey();
            win_key.key_pressed.connect((kv, kc, mstate) => {
                bool ctrl = (mstate & Gdk.ModifierType.CONTROL_MASK) != 0;
                if (ctrl && kv == Gdk.Key.a) {
                    _proc_sel.select_all();
                    return true;
                }
                if (ctrl && kv == Gdk.Key.k) {
                    var sel = get_selected_procs();
                    if (sel.length == 0) return false;
                    if (sel.length > 1) {
                        confirm_signal_multi(sel, Posix.Signal.KILL, "Force Kill",
                            "Sends SIGKILL to %d processes.".printf(sel.length));
                    } else {
                        confirm_signal(sel[0], Posix.Signal.KILL, "Force Kill",
                            "Sends SIGKILL - the process is immediately terminated.");
                    }
                    return true;
                }
                if (_search_bubble != null && !_search_bubble.visible) {
                    unichar uc = Gdk.keyval_to_unicode(kv);
                    if (uc >= 0x20 && uc != 0x7F) {
                        open_search(uc.to_string());
                        return true;
                    }
                }
                return false;
            });
            ((Gtk.Widget)main_window).add_controller(win_key);

            // Start timers
            prev_procs = new HashTable<int, ProcessInfo>(null, null);
            _resource_timer = Timeout.add(1500, on_resource_tick);
                _process_timer  = Timeout.add_seconds(_process_interval_sec, () => { if (!_menu_open) refresh_processes(); return true; });
            on_resource_tick();
            refresh_processes();

            main_window.close_request.connect(() => {
                if (_resource_timer  != 0) { Source.remove(_resource_timer);  _resource_timer  = 0; }
                if (_process_timer   != 0) { Source.remove(_process_timer);   _process_timer   = 0; }
                if (_proc_refresh_id != 0) { Source.remove(_proc_refresh_id); _proc_refresh_id = 0; }
                return false;
            });

            main_window.present();
        }

        private void open_search(string initial) {
            if (_search_bubble == null) return;
            search_entry_widget.text = initial;
            search_entry_widget.grab_focus();
            search_entry_widget.set_position(-1);
        }

        private void close_search() {
            if (_search_bubble == null) return;
            _proc_search_text = "";
            search_entry_widget.text = "";
            _proc_list_model.search = "";
            refresh_processes();
        }

        // ── Resources column (left panel) ───────────────────────────────────

        private Widget build_resources_column() {
            var col = new Box(Orientation.VERTICAL, 12);
            col.margin_bottom = 16;
            col.margin_start  = 14;
            col.margin_end    = 14;

            // CPU card
            cpu_value_lbl = new Label("0%");
            cpu_sub_lbl   = new Label("Loading…");
            cpu_spark     = new SparkLine(60, "#3584e4", "#3584e4");
            var cpu_card  = make_stat_card("CPU", "computer-symbolic", cpu_spark, cpu_value_lbl, cpu_sub_lbl);

            core_bars_box = new Box(Orientation.HORIZONTAL, 3);
            core_bars_box.margin_start  = 14;
            core_bars_box.margin_end    = 14;
            core_bars_box.margin_bottom = 10;
            core_bars_box.set_size_request(-1, 28);
            for (int i = 0; i < num_cores; i++) {
                core_bars[i] = new MiniBar("#3584e4");
                core_bars[i].hexpand = true;
                core_bars_box.append(core_bars[i]);
            }
            cpu_card.append(core_bars_box);

            // Memory card
            mem_value_lbl = new Label("0%");
            mem_sub_lbl   = new Label("");
            mem_spark     = new SparkLine(60, "#9b59b6", "#9b59b6");
            var mem_card  = make_stat_card("Memory", "drive-multidisk-symbolic", mem_spark, mem_value_lbl, mem_sub_lbl);

            // Disk card
            disk_value_lbl = new Label("0 KB/s");
            disk_sub_lbl   = new Label("");
            disk_read_spark  = new SparkLine(60, "#2ecc71", "#2ecc71");
            disk_write_spark = new SparkLine(60, "#e74c3c", "#e74c3c");
            var disk_overlay = build_dual_chart(disk_read_spark, disk_write_spark);
            var disk_card    = build_dual_card("Disk I/O", "drive-harddisk-symbolic",
                                               disk_value_lbl, disk_sub_lbl, disk_overlay);

            // Network card
            net_value_lbl = new Label("↓ 0 KB/s");
            net_sub_lbl   = new Label("");
            net_rx_spark  = new SparkLine(60, "#f39c12", "#f39c12");
            net_tx_spark  = new SparkLine(60, "#1abc9c", "#1abc9c");
            var net_overlay = build_dual_chart(net_rx_spark, net_tx_spark);
            var net_card    = build_dual_card("Network", "network-wired-symbolic",
                                              net_value_lbl, net_sub_lbl, net_overlay);

            col.append(cpu_card);
            col.append(mem_card);
            col.append(disk_card);
            col.append(net_card);

            return col;
        }

        private Overlay build_dual_chart(SparkLine a, SparkLine b) {
            var ov = new Overlay();
            a.hexpand = true; a.vexpand = true;
            b.hexpand = true; b.vexpand = true;
            ov.set_child(a);
            ov.add_overlay(b);
            return ov;
        }

        private Box build_dual_card(string title, string icon,
                                    Label val_lbl, Label sub_lbl, Widget chart) {
            var card = new Box(Orientation.VERTICAL, 0);
            card.add_css_class("monitor-card");

            var hdr = new Box(Orientation.HORIZONTAL, 6);
            hdr.margin_top    = 12;
            hdr.margin_start  = 14;
            hdr.margin_end    = 14;
            hdr.margin_bottom = 4;

            var ic = new Image.from_icon_name(icon);
            ic.pixel_size = 16; ic.opacity = 0.7;
            hdr.append(ic);

            var ttl = new Label(title);
            ttl.add_css_class("monitor-card-title");
            ttl.hexpand = true; ttl.halign = Align.START;
            hdr.append(ttl);

            val_lbl.add_css_class("monitor-card-value");
            hdr.append(val_lbl);
            card.append(hdr);

            sub_lbl.add_css_class("monitor-card-sub");
            sub_lbl.halign       = Align.START;
            sub_lbl.margin_start = 14;
            sub_lbl.margin_bottom = 2;
            card.append(sub_lbl);

            chart.margin_top    = 4;
            chart.margin_bottom = 8;
            chart.margin_start  = 14;
            chart.margin_end    = 14;
            chart.vexpand       = true;
            ((Widget)chart).set_size_request(-1, 60);
            card.append(chart);

            return card;
        }

        // ── Processes panel (right panel) ───────────────────────────────────

        private Widget build_processes_panel() {
            // List model
            proc_store = new GLib.ListStore(typeof(ProcessInfo));
            _proc_list_model = new ProcessListModel();
            _proc_sel = new SingleSelection(_proc_list_model);

            // GroupedDataListView owns the scroll, column view, view-edge
            // reserve and the singularity-data-view styling. Monitor only
            // adds its custom column factories below and the
            // monitor-proc-view CSS hook for the process-specific tweaks.
            var view = new Singularity.Widgets.GroupedDataListView();
            view.set_selection_model(_proc_sel);
            proc_view = view.column_view;
            proc_view.add_css_class("monitor-proc-view");

            // Process name column - handles both ProcessGroup and ProcessInfo
            var name_factory = new SignalListItemFactory();
            name_factory.setup.connect((item) => {
                var li   = (ListItem)item;
                var row  = new Box(Orientation.HORIZONTAL, 8);
                var icon = new Image.from_icon_name("system-run-symbolic");
                icon.pixel_size = 16;
                var expander = new Image();
                expander.pixel_size = 12;
                expander.visible = false;
                var lbl  = new Label("");
                lbl.halign = Align.START;
                lbl.hexpand = true;
                var badge = new Label("");
                badge.add_css_class("dim-label");
                badge.add_css_class("caption");
                row.append(expander);
                row.append(icon);
                row.append(lbl);
                row.append(badge);

                var gesture = new GestureClick();
                gesture.button = 3;
                gesture.pressed.connect((n, x, y) => {
                    Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
                    var p = row.get_data<ProcessInfo>("proc-info");
                    var g = row.get_data<ProcessGroup>("proc-group");
                    if (p != null) {
                        show_proc_context_menu(row, { p }, rect);
                    } else if (g != null) {
                        show_group_context_menu(row, g, rect);
                    }
                });
                row.add_controller(gesture);

                var click = new GestureClick();
                click.pressed.connect((n, x, y) => {
                    var g = row.get_data<ProcessGroup>("proc-group");
                    if (g != null) {
                        _proc_list_model.toggle_group(g);
                    }
                });
                row.add_controller(click);
                li.set_child(row);
            });
            name_factory.bind.connect((item) => {
                var li  = (ListItem)item;
                var row = (Box)li.get_child();
                var expander = (Image)row.get_first_child();
                var icon = (Image)expander.get_next_sibling();
                var lbl = (Label)icon.get_next_sibling();
                var badge = (Label)lbl.get_next_sibling();
                var obj = li.get_item();

                var pg = obj as ProcessGroup;
                var pi = obj as ProcessInfo;

                row.set_data<ProcessGroup>("proc-group", null);
                row.set_data<ProcessInfo>("proc-info", null);

                if (pg != null) {
                    icon.set_from_icon_name(pg.icon_name);
                    lbl.label = pg.name;
                    badge.label = "%d".printf(pg.count);
                    expander.set_from_icon_name(pg.expanded
                        ? "go-down-symbolic" : "go-next-symbolic");
                    expander.visible = true;
                    badge.visible = true;
                    row.set_data<ProcessGroup>("proc-group", pg);
                } else if (pi != null) {
                    icon.set_from_icon_name(pi.icon_name);
                    lbl.label = pi.name;
                    badge.label = "";
                    badge.visible = false;
                    expander.visible = (pi != null && pi.group_key != "");
                    expander.set_from_icon_name("");
                    row.set_data<ProcessInfo>("proc-info", pi);
                }
            });
            name_factory.unbind.connect((item) => {
                var li  = (ListItem)item;
                var row = (Box)li.get_child();
                if (row != null) row.set_data<ProcessInfo>("proc-info", null);
            });
            var name_col = new ColumnViewColumn("Process", name_factory);
            name_col.expand = true;
            proc_view.append_column(name_col);

            proc_view.append_column(make_proc_column("PID", 70, (item) => {
                var pi = item as ProcessInfo;
                var lbl = new Label(pi != null ? pi.pid.to_string() : "-");
                lbl.halign = Align.END;
                lbl.add_css_class("monospace");
                lbl.add_css_class("dim-label");
                return lbl;
            }));
            proc_view.append_column(make_proc_column("CPU %", 80, (item) => {
                var pg = item as ProcessGroup;
                var pi = item as ProcessInfo;
                double cpu = pg != null ? pg.cpu : (pi != null ? pi.cpu : 0);
                var lbl = new Label("%.1f%%".printf(cpu));
                lbl.halign = Align.END;
                if (cpu > 50) lbl.add_css_class("monitor-high");
                else if (cpu > 20) lbl.add_css_class("monitor-med");
                return lbl;
            }));
            proc_view.append_column(make_proc_column("Memory", 90, (item) => {
                var pg = item as ProcessGroup;
                var pi = item as ProcessInfo;
                ulong mem = pg != null ? pg.mem_kb : (pi != null ? pi.mem_kb : 0);
                var lbl = new Label(format_kb(mem));
                lbl.halign = Align.END;
                return lbl;
            }));
            proc_view.append_column(make_proc_column("User", 90, (item) => {
                var pi = item as ProcessInfo;
                var lbl = new Label(pi != null ? pi.user : "");
                lbl.halign = Align.START;
                lbl.add_css_class("dim-label");
                return lbl;
            }));

            return view;
        }

        private ProcessInfo[] get_selected_procs() {
            ProcessInfo[] result = {};
            var bitset = _proc_sel.get_selection();
            Gtk.BitsetIter iter = Gtk.BitsetIter();
            uint pos;
            bool valid = iter.init_first(bitset, out pos);
            while (valid) {
                var item = _proc_sel.get_item(pos);
                var pi = item as ProcessInfo;
                var pg = item as ProcessGroup;
                if (pi != null) {
                    result += pi;
                } else if (pg != null) {
                    foreach (var p in pg.processes)
                        result += p;
                }
                valid = iter.next(out pos);
            }
            return result;
        }

        private void show_proc_context_menu(Widget widget, ProcessInfo[] procs, Gdk.Rectangle rect) {
            if (procs.length == 0) return;
            bool multi = procs.length > 1;
            ProcessInfo p = procs[0];

            var menu = new Singularity.Widgets.ContextMenu(widget);
            menu.set_pointing_to(rect);
            _menu_open = true;
            menu.closed.connect(() => {
                _menu_open = false;
                if (_pending_refresh) { _pending_refresh = false; refresh_processes(); }
            });

            string end_label   = multi ? "End %d Processes".printf(procs.length)   : "End Process";
            string kill_label  = multi ? "Kill %d Processes".printf(procs.length)  : "Force Kill";

            menu.add_item(end_label, "process-stop-symbolic", () => {
                if (multi) {
                    confirm_signal_multi(procs, Posix.Signal.TERM, "End",
                        "Sends SIGTERM to %d processes.".printf(procs.length));
                } else {
                    confirm_signal(p, Posix.Signal.TERM, "End",
                        "Sends SIGTERM - the process can clean up before exiting.");
                }
            });
            menu.add_item(kill_label, "edit-delete-symbolic", () => {
                if (multi) {
                    confirm_signal_multi(procs, Posix.Signal.KILL, "Force Kill",
                        "Sends SIGKILL to %d processes.".printf(procs.length));
                } else {
                    confirm_signal(p, Posix.Signal.KILL, "Force Kill",
                        "Sends SIGKILL - the process is immediately terminated.");
                }
            });
            menu.add_separator();
            menu.add_item("Suspend", "media-playback-pause-symbolic", () => {
                foreach (var proc in procs)
                    Posix.kill((Posix.pid_t)proc.pid, Posix.Signal.STOP);
                _pending_refresh = true;
            });
            menu.add_item("Resume", "media-playback-start-symbolic", () => {
                foreach (var proc in procs)
                    Posix.kill((Posix.pid_t)proc.pid, Posix.Signal.CONT);
                _pending_refresh = true;
            });
            if (!multi) {
                menu.add_separator();
                menu.add_item("Properties", "document-properties-symbolic", () => {
                    show_proc_properties(p);
                });
                menu.add_item("Memory Maps", "emblem-system-symbolic", () => {
                    show_proc_maps(p);
                });
                menu.add_item("Open Files", "folder-open-symbolic", () => {
                    show_proc_open_files(p);
                });
            }
            menu.add_separator();
            menu.add_item("Copy Name", "edit-copy-symbolic", () => {
                main_window.get_clipboard().set_text(p.name);
            });
            menu.add_item("Copy PID", "edit-copy-symbolic", () => {
                main_window.get_clipboard().set_text(p.pid.to_string());
            });

            menu.popup();
        }

        private void show_group_context_menu(Widget widget, ProcessGroup g, Gdk.Rectangle rect) {
            var procs = g.processes.to_array();
            if (procs.length == 0) return;

            var menu = new Singularity.Widgets.ContextMenu(widget);
            menu.set_pointing_to(rect);
            _menu_open = true;
            menu.closed.connect(() => {
                _menu_open = false;
                if (_pending_refresh) { _pending_refresh = false; refresh_processes(); }
            });

            menu.add_item("End %d Processes".printf(procs.length), "process-stop-symbolic", () => {
                confirm_signal_multi(procs, Posix.Signal.TERM, "End",
                    "Sends SIGTERM to %d processes in group \"%s\".".printf(procs.length, g.name));
            });
            menu.add_item("Force Kill %d Processes".printf(procs.length), "edit-delete-symbolic", () => {
                confirm_signal_multi(procs, Posix.Signal.KILL, "Force Kill",
                    "Sends SIGKILL to %d processes in group \"%s\".".printf(procs.length, g.name));
            });
            menu.add_separator();
            menu.add_item("Suspend All", "media-playback-pause-symbolic", () => {
                foreach (var p in procs)
                    Posix.kill((Posix.pid_t)p.pid, Posix.Signal.STOP);
                _pending_refresh = true;
            });
            menu.add_item("Resume All", "media-playback-start-symbolic", () => {
                foreach (var p in procs)
                    Posix.kill((Posix.pid_t)p.pid, Posix.Signal.CONT);
                _pending_refresh = true;
            });
            menu.add_separator();
            menu.add_item("Copy Group Name", "edit-copy-symbolic", () => {
                main_window.get_clipboard().set_text(g.name);
            });

            menu.popup();
        }

        private void confirm_signal_multi(ProcessInfo[] procs, int sig, string action, string detail) {
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, true);
            dialog.set_title("%s %d processes?".printf(action, procs.length));
            dialog.transient_for = main_window;
            dialog.set_default_size(360, 220);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = box.margin_bottom = 24;
            box.margin_start = box.margin_end = 24;

            var lbl = new Label(detail);
            lbl.wrap = true;
            lbl.halign = Align.START;
            box.append(lbl);

            var btns = new Box(Orientation.HORIZONTAL, 8);
            btns.halign = Align.END;
            btns.margin_top = 8;

            var cancel_btn = new Button.with_label("Cancel");
            cancel_btn.clicked.connect(() => dialog.close());
            btns.append(cancel_btn);

            var confirm_btn = new Button.with_label(action);
            confirm_btn.add_css_class("destructive-action");
            confirm_btn.clicked.connect(() => {
                foreach (var proc in procs)
                    Posix.kill((Posix.pid_t)proc.pid, sig);
                _pending_refresh = true;
                dialog.close();
            });
            btns.append(confirm_btn);

            box.append(btns);
            dialog.content_box.append(box);
            dialog.present();
        }

        private void confirm_signal(ProcessInfo p, int sig, string action, string detail) {
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, true);
            dialog.set_title("%s \"%s\"?".printf(action, p.name));
            dialog.transient_for = main_window;
            dialog.set_default_size(360, 220);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = box.margin_bottom = 24;
            box.margin_start = box.margin_end = 24;

            var lbl = new Label(detail + "\n\nPID: %d".printf(p.pid));
            lbl.wrap = true;
            lbl.halign = Align.START;
            box.append(lbl);

            var btns = new Box(Orientation.HORIZONTAL, 8);
            btns.halign = Align.END;
            btns.margin_top = 8;

            var cancel_btn = new Button.with_label("Cancel");
            cancel_btn.clicked.connect(() => dialog.close());
            btns.append(cancel_btn);

            var confirm_btn = new Button.with_label(action);
            confirm_btn.add_css_class("destructive-action");
            confirm_btn.clicked.connect(() => {
                Posix.kill((Posix.pid_t)p.pid, sig);
                refresh_processes();
                dialog.close();
            });
            btns.append(confirm_btn);

            box.append(btns);
            dialog.content_box.append(box);
            dialog.present();
        }

        private void show_proc_properties(ProcessInfo p) {
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.set_title("Properties");
            dialog.transient_for = main_window;
            dialog.set_default_size(400, 460);

            var box = new Box(Orientation.VERTICAL, 18);
            box.margin_top = box.margin_bottom = 28;
            box.margin_start = box.margin_end = 28;

            var icon = new Image.from_icon_name("system-run-symbolic");
            icon.pixel_size = 64;
            icon.halign = Align.CENTER;
            box.append(icon);

            var name_lbl = new Label(p.name);
            name_lbl.add_css_class("title-2");
            name_lbl.halign = Align.CENTER;
            name_lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name_lbl.max_width_chars = 32;
            box.append(name_lbl);

            box.append(new Separator(Orientation.HORIZONTAL));

            var grid = new Grid();
            grid.column_spacing = 16;
            grid.row_spacing    = 10;
            grid.halign         = Align.FILL;
            grid.hexpand        = true;
            int grow = 0;
            void add_row(string key, string val) {
                var k = new Label(key);
                k.halign = Align.END;
                k.add_css_class("dim-label");
                k.add_css_class("caption");
                var v = new Label(val);
                v.halign = Align.START;
                v.selectable = true;
                v.ellipsize = Pango.EllipsizeMode.MIDDLE;
                v.max_width_chars = 26;
                grid.attach(k, 0, grow);
                grid.attach(v, 1, grow);
                grow++;
            }

            add_row("PID:", p.pid.to_string());
            add_row("User:", p.user);

            string status_text = "";
            try { FileUtils.get_contents("/proc/%d/status".printf(p.pid), out status_text); } catch {}
            string[] want = { "State", "PPid", "Threads", "VmRSS", "VmSize", "VmPeak" };
            foreach (var line in status_text.split("\n")) {
                var parts = line.split(":", 2);
                if (parts.length < 2) continue;
                string key = parts[0].strip();
                foreach (var w in want)
                    if (w == key) { add_row(key + ":", parts[1].strip()); break; }
            }

            string cmdline = "";
            try {
                FileUtils.get_contents("/proc/%d/cmdline".printf(p.pid), out cmdline);
                cmdline = cmdline.replace("\0", " ").strip();
            } catch {}
            if (cmdline != "") add_row("Command:", cmdline);

            box.append(grid);

            var close_btn = new Button.with_label("Close");
            close_btn.halign = Align.END;
            close_btn.add_css_class("close-button");
            close_btn.clicked.connect(() => dialog.close());
            box.append(close_btn);

            dialog.content_box.append(box);
            dialog.present();
        }

        private void show_proc_maps(ProcessInfo p) {
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.set_title("Memory Maps - %s".printf(p.name));
            dialog.transient_for = main_window;
            dialog.set_default_size(860, 520);

            var store = new GLib.ListStore(typeof(MemMapEntry));
            string maps_text = "";
            try { FileUtils.get_contents("/proc/%d/maps".printf(p.pid), out maps_text); } catch {}
            foreach (var line in maps_text.split("\n")) {
                if (line.strip() == "") continue;
                // format: addr-addr perms offset dev inode [path]
                var tok = line.split_set(" \t");
                string addr_range = "", perms = "", pathname = "";
                int fi = 0;
                foreach (var t in tok) {
                    if (t == "") continue;
                    switch (fi) {
                        case 0: addr_range = t; break;
                        case 1: perms = t; break;
                        case 5: pathname = t; break;
                    }
                    fi++;
                }
                // compute size
                string size_str = "";
                var range = addr_range.split("-");
                if (range.length == 2) {
                    uint64 start = uint64.parse("0x" + range[0]);
                    uint64 end   = uint64.parse("0x" + range[1]);
                    uint64 sz    = end - start;
                    if (sz >= 1024 * 1024)
                        size_str = "%.1f MB".printf((double)sz / 1024 / 1024);
                    else if (sz >= 1024)
                        size_str = "%llu KB".printf(sz / 1024);
                    else
                        size_str = "%llu B".printf(sz);
                }
                // shorten address - show only start
                string addr_short = range.length == 2 ? range[0] : addr_range;
                // name
                string name = pathname != "" ? GLib.Path.get_basename(pathname) : "[anonymous]";
                if (pathname.has_prefix("[")) name = pathname;

                var entry = new MemMapEntry();
                entry.addr  = addr_short;
                entry.size  = size_str;
                entry.perms = perms;
                entry.name  = name;
                store.append(entry);
            }

            var sel = new NoSelection(store);
            var cv  = new ColumnView(sel);
            cv.show_column_separators = false;
            cv.show_row_separators    = true;
            cv.hexpand = true;
            cv.vexpand = true;
            cv.append_column(make_str_col("Address",     130, false, (o) => ((MemMapEntry)o).addr));
            cv.append_column(make_str_col("Size",         80, false, (o) => ((MemMapEntry)o).size));
            cv.append_column(make_str_col("Permissions",  90, false, (o) => ((MemMapEntry)o).perms));
            cv.append_column(make_str_col("Name / Path", 200, true,  (o) => ((MemMapEntry)o).name));

            var scroll = new ScrolledWindow();
            scroll.set_child(cv);
            scroll.vexpand = true;
            scroll.hexpand = true;
            scroll.margin_bottom = 8;

            var close_btn_maps = new Button.with_label("Close");
            close_btn_maps.halign = Align.END;
            close_btn_maps.margin_top = 8;
            close_btn_maps.margin_bottom = 8;
            close_btn_maps.margin_end = 8;
            close_btn_maps.add_css_class("close-button");
            close_btn_maps.clicked.connect(() => dialog.close());

            dialog.content_box.append(scroll);
            dialog.content_box.append(close_btn_maps);
            dialog.present();
        }

        private void show_proc_open_files(ProcessInfo p) {
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.set_title("Open Files - %s".printf(p.name));
            dialog.transient_for = main_window;
            dialog.set_default_size(640, 460);

            var store = new GLib.ListStore(typeof(FdEntry));
            try {
                var fd_dir = File.new_for_path("/proc/%d/fd".printf(p.pid));
                var en = fd_dir.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? fi;
                while ((fi = en.next_file()) != null) {
                    string fd_name = fi.get_name();
                    string target = "";
                    try { target = GLib.FileUtils.read_link("/proc/%d/fd/%s".printf(p.pid, fd_name)); } catch {}
                    string type = "file";
                    if (target.has_prefix("socket:")) type = "socket";
                    else if (target.has_prefix("pipe:")) type = "pipe";
                    else if (target.has_prefix("anon_inode:")) type = "anon";
                    else if (target == "") type = "?";

                    var entry = new FdEntry();
                    entry.fd   = fd_name;
                    entry.kind = type;
                    entry.path = target;
                    store.append(entry);
                }
            } catch {}

            var sel = new NoSelection(store);
            var cv  = new ColumnView(sel);
            cv.show_column_separators = false;
            cv.show_row_separators    = true;
            cv.hexpand = true;
            cv.vexpand = true;
            cv.append_column(make_str_col("FD",   48, false, (o) => ((FdEntry)o).fd));
            cv.append_column(make_str_col("Type", 72, false, (o) => ((FdEntry)o).kind));
            cv.append_column(make_str_col("Path", 200, true, (o) => ((FdEntry)o).path));

            var scroll = new ScrolledWindow();
            scroll.set_child(cv);
            scroll.vexpand = true;
            scroll.hexpand = true;
            scroll.margin_bottom = 8;

            var close_btn_files = new Button.with_label("Close");
            close_btn_files.halign = Align.END;
            close_btn_files.margin_top = 8;
            close_btn_files.margin_bottom = 8;
            close_btn_files.margin_end = 8;
            close_btn_files.add_css_class("close-button");
            close_btn_files.clicked.connect(() => dialog.close());

            dialog.content_box.append(scroll);
            dialog.content_box.append(close_btn_files);
            dialog.present();
        }

        private ColumnViewColumn make_str_col(string title, int width, bool expand,
                                               owned StrExtractor fn) {
            var factory = new SignalListItemFactory();
            factory.setup.connect((item) => {
                var li  = (ListItem)item;
                var lbl = new Label("");
                lbl.halign = Align.START;
                lbl.xalign = 0;
                lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
                li.child = lbl;
            });
            factory.bind.connect((item) => {
                var li = (ListItem)item;
                ((Label)li.child).label = fn(li.item);
            });
            var col = new ColumnViewColumn(title, factory);
            col.fixed_width = width;
            col.expand      = expand;
            return col;
        }

        private ColumnViewColumn make_proc_column(string title, int width,
                                                   owned ProcColFactory factory_fn) {
            var factory = new SignalListItemFactory();
            factory.bind.connect((item) => {
                var li = (ListItem)item;
                li.child = factory_fn(li.item);
            });
            factory.unbind.connect((item) => {
                ((ListItem)item).child = null;
            });
            var col = new ColumnViewColumn(title, factory);
            col.fixed_width = width;
            col.expand      = (width > 100);
            return col;
        }

        // ── Stats update ────────────────────────────────────────────────────

        private bool on_resource_tick() {
            update_cpu();
            update_memory();
            update_disk();
            update_network();
            push_dock_widgets();
            return true;
        }

        private void push_dock_widgets() {
            if (_dock == null) {
                try {
                    _dock = Bus.get_proxy_sync<DockSurface>(BusType.SESSION,
                        "dev.sinty.Dock", "/dev/sinty/Dock");
                } catch (Error e) { return; }
            }
            try {
                var arr = new VariantBuilder(new VariantType("a(sa{sv})"));
                arr.add_value(build_circular("cpu", _last_cpu_pct, "CPU", "#3584e4"));
                arr.add_value(build_circular("mem", _last_mem_pct, "Memory", "#33d17a"));
                _dock.SetSuffix("dev.sinty.monitor", arr.end());
            } catch (Error e) {
                _dock = null;
            }
        }

        private Variant build_circular(string id, double fraction, string tooltip, string color) {
            var props = new VariantBuilder(VariantType.VARDICT);
            props.add("{sv}", "id", new Variant.string(id));
            props.add("{sv}", "fraction", new Variant.double(fraction));
            props.add("{sv}", "label", new Variant.string("%d".printf((int)(fraction * 100))));
            props.add("{sv}", "diameter", new Variant.int32(32));
            props.add("{sv}", "tooltip", new Variant.string(tooltip));
            props.add("{sv}", "color", new Variant.string(color));
            // Build the tuple via Variant.tuple - avoids the g_variant_new
            // format-string trap where "a{sv}" expects a builder, not a variant.
            return new Variant.tuple({
                new Variant.string("circular_progress"),
                props.end()
            });
        }

        private void update_cpu() {
            try {
                string content;
                FileUtils.get_contents("/proc/stat", out content);
                var lines = content.split("\n");

                // Global
                foreach (var line in lines) {
                    if (line.has_prefix("cpu ")) {
                        var v = parse_cpu_line(line);
                        ulong total = 0; foreach (var x in v) total += x;
                        ulong idle  = v.length >= 4 ? v[3] : 0;
                        ulong dt    = total - cpu_last_total;
                        ulong di    = idle  - cpu_last_idle;
                        double pct  = (dt > 0) ? (double)(dt - di) / dt : 0;
                        cpu_last_total = total; cpu_last_idle = idle;
                        _last_cpu_pct = pct;
                        cpu_spark.push(pct);
                        cpu_value_lbl.label = "%d%%".printf((int)(pct * 100));
                        break;
                    }
                }

                // Get CPU model name
                try {
                    string cpuinfo;
                    FileUtils.get_contents("/proc/cpuinfo", out cpuinfo);
                    foreach (var cl in cpuinfo.split("\n")) {
                        if (cl.has_prefix("model name")) {
                            var parts = cl.split(":");
                            if (parts.length >= 2)
                                cpu_sub_lbl.label = parts[1].strip();
                            break;
                        }
                    }
                } catch {}

                // Per-core
                int core_idx = 0;
                foreach (var line in lines) {
                    if (core_idx >= num_cores) break;
                    if (line.has_prefix("cpu") && !line.has_prefix("cpu ")) {
                        var v = parse_cpu_line(line);
                        ulong total = 0; foreach (var x in v) total += x;
                        ulong idle  = v.length >= 4 ? v[3] : 0;
                        ulong dt    = total - core_last_total[core_idx];
                        ulong di    = idle  - core_last_idle[core_idx];
                        double pct  = (dt > 0) ? (double)(dt - di) / dt : 0;
                        core_last_total[core_idx] = total;
                        core_last_idle[core_idx]  = idle;
                        if (core_idx < core_bars.length)
                            core_bars[core_idx].set_value(pct);
                        core_idx++;
                    }
                }
            } catch {}
        }

        private ulong[] parse_cpu_line(string line) {
            ulong[] vals = {};
            var parts = line.split(" ");
            foreach (var p in parts) {
                if (p.length > 0 && p[0].isdigit()) vals += ulong.parse(p);
            }
            return vals;
        }

        private void update_memory() {
            try {
                string content;
                FileUtils.get_contents("/proc/meminfo", out content);
                ulong total = 0, available = 0, cached = 0, buffers = 0;
                foreach (var line in content.split("\n")) {
                    if      (line.has_prefix("MemTotal:"))     total     = parse_kb(line);
                    else if (line.has_prefix("MemAvailable:")) available = parse_kb(line);
                    else if (line.has_prefix("Cached:"))       cached    = parse_kb(line);
                    else if (line.has_prefix("Buffers:"))      buffers   = parse_kb(line);
                }
                if (total > 0) {
                    ulong used = total - available;
                    double pct = (double)used / total;
                    _last_mem_pct = pct;
                    mem_spark.push(pct);
                    mem_value_lbl.label = "%d%%".printf((int)(pct * 100));
                    mem_sub_lbl.label   = "%s / %s  (cached %s)".printf(
                        format_kb(used), format_kb(total), format_kb(cached + buffers));
                }
            } catch {}
        }

        private void update_disk() {
            try {
                string content;
                FileUtils.get_contents("/proc/diskstats", out content);
                ulong total_read = 0, total_write = 0;
                foreach (var line in content.split("\n")) {
                    var parts = line.strip().split_set(" \t");
                    // Only count real block devices (sda, nvme, vda…) - skip partitions
                    if (parts.length < 13) continue;
                    string dev = parts[2];
                    if (!is_disk_device(dev)) continue;
                    total_read  += ulong.parse(parts[5]);  // sectors read
                    total_write += ulong.parse(parts[9]);  // sectors written
                }
                ulong dr = (total_read  >= disk_last_read)  ? total_read  - disk_last_read  : 0;
                ulong dw = (total_write >= disk_last_write) ? total_write - disk_last_write : 0;
                disk_last_read  = total_read;
                disk_last_write = total_write;

                // sectors = 512 bytes
                ulong read_kbs  = dr * 512 / 1024;
                ulong write_kbs = dw * 512 / 1024;
                double max_kbs = 500 * 1024.0; // normalise to 500 MB/s

                disk_read_spark.push((double)read_kbs  / max_kbs);
                disk_write_spark.push((double)write_kbs / max_kbs);
                disk_value_lbl.label = "↑ %s/s".printf(format_kb(write_kbs));
                disk_sub_lbl.label   = "↓ %s/s read".printf(format_kb(read_kbs));
            } catch {}
        }

        private bool is_disk_device(string dev) {
            if (dev.has_prefix("sd") || dev.has_prefix("vd") || dev.has_prefix("hd"))
                return dev.length == 3 || (dev.length > 3 && dev[3].isdigit() == false);
            if (dev.has_prefix("nvme"))
                return !dev.contains("p");
            if (dev.has_prefix("mmcblk"))
                return !dev.contains("p");
            if (dev.has_prefix("dm-") || dev.has_prefix("loop"))
                return false;
            return false;
        }

        private void update_network() {
            try {
                string content;
                FileUtils.get_contents("/proc/net/dev", out content);
                ulong total_rx = 0, total_tx = 0;
                foreach (var line in content.split("\n")) {
                    var stripped = line.strip();
                    if (stripped.has_prefix("lo:") || !stripped.contains(":")) continue;
                    var parts = stripped.split(":");
                    if (parts.length < 2) continue;
                    var vals = parts[1].strip().split_set(" \t");
                    ulong[] nums = {};
                    foreach (var v in vals) if (v != "" && v[0].isdigit()) nums += ulong.parse(v);
                    if (nums.length >= 9) { total_rx += nums[0]; total_tx += nums[8]; }
                }
                ulong dr = (total_rx >= net_last_rx) ? total_rx - net_last_rx : 0;
                ulong dt = (total_tx >= net_last_tx) ? total_tx - net_last_tx : 0;
                net_last_rx = total_rx; net_last_tx = total_tx;

                ulong rx_kbs = dr / 1024;
                ulong tx_kbs = dt / 1024;
                double max_kbs = 100 * 1024.0; // 100 MB/s

                net_rx_spark.push((double)rx_kbs / max_kbs);
                net_tx_spark.push((double)tx_kbs / max_kbs);
                net_value_lbl.label = "↓ %s/s".printf(format_kb(rx_kbs));
                net_sub_lbl.label   = "↑ %s/s sent".printf(format_kb(tx_kbs));
            } catch {}
        }

        // ── Process list ────────────────────────────────────────────────────

        private void refresh_processes() {
            var new_procs = new HashTable<int, ProcessInfo>(null, null);
            ulong sys_hz = get_hz();
            ulong uptime_ticks = get_uptime_ticks();

            try {
                var proc_dir = Dir.open("/proc");
                string? entry;
                while ((entry = proc_dir.read_name()) != null) {
                    if (!entry[0].isdigit()) continue;
                    int pid = int.parse(entry);
                    var info = read_process_info(pid, sys_hz, uptime_ticks);
                    if (info != null) new_procs.insert(pid, info);
                }
            } catch {}

            // Compute CPU delta
            new_procs.foreach((pid, info) => {
                var prev = prev_procs.lookup(pid);
                if (prev != null) {
                    ulong du = info.prev_utime - prev.prev_utime;
                    ulong ds = info.prev_stime - prev.prev_stime;
                    info.cpu = (double)(du + ds) / ((double)sys_hz * (double)_process_interval_sec) * 100.0 / (double)num_cores;
                    info.cpu = info.cpu.clamp(0, 999);
                }
            });
            prev_procs = new_procs;

            // Update existing objects in-place so GTK doesn't lose selection
            // or scroll position. Build a list for the grouped model.
            Gee.ArrayList<ProcessInfo> proc_list = new Gee.ArrayList<ProcessInfo>();
            new_procs.foreach((pid, info) => {
                string gk = info.name;
                if (gk.has_prefix("singularity-")) gk = gk.substring(11);
                info.group_key = gk;
                proc_list.add(info);
            });
            _proc_list_model.update(proc_list, _proc_list_model.search);
        }

        private ProcessInfo? read_process_info(int pid, ulong hz, ulong uptime) {
            try {
                // Name
                string comm;
                FileUtils.get_contents("/proc/%d/comm".printf(pid), out comm);

                // Stat for CPU ticks + state
                string stat_content;
                FileUtils.get_contents("/proc/%d/stat".printf(pid), out stat_content);
                var stat_parts = stat_content.split(" ");
                if (stat_parts.length < 17) return null;

                ulong utime = ulong.parse(stat_parts[13]);
                ulong stime = ulong.parse(stat_parts[14]);
                string state = stat_parts[2];

                // Memory (VmRSS from status)
                ulong mem_kb = 0;
                try {
                    string status_content;
                    FileUtils.get_contents("/proc/%d/status".printf(pid), out status_content);
                    foreach (var line in status_content.split("\n")) {
                        if (line.has_prefix("VmRSS:")) {
                            mem_kb = parse_kb(line);
                            break;
                        }
                    }
                } catch {}

                // User
                string user = "";
                try {
                    var f = File.new_for_path("/proc/%d".printf(pid));
                    var fi = f.query_info("owner::user", FileQueryInfoFlags.NONE);
                    user = fi.get_attribute_string("owner::user") ?? "";
                } catch {}

                var info = new ProcessInfo();
                info.pid        = pid;
                info.name       = comm.strip();
                info.icon_name  = _resolve_icon(comm.strip(), pid);
                info.state      = state;
                info.mem_kb     = mem_kb;
                info.user       = user;
                info.prev_utime = utime;
                info.prev_stime = stime;
                return info;
            } catch {
                return null;
            }
        }

        // ── Helpers ─────────────────────────────────────────────────────────

        private static HashTable<string, string> _icon_cache;
        private static HashTable<string, string>? _cmd_to_icon = null;

        private string _resolve_icon(string name, int pid) {
            if (_icon_cache == null)
                _icon_cache = new HashTable<string, string>(str_hash, str_equal);

            if (_icon_cache.contains(name))
                return _icon_cache.get(name);

            string icon = "system-run-symbolic";

            // Build a cmdline-to-icon map on first call
            if (_cmd_to_icon == null) {
                _cmd_to_icon = new HashTable<string, string>(str_hash, str_equal);
                try {
                    foreach (var ai in GLib.AppInfo.get_all()) {
                        var cmd = ai.get_executable();
                        if (cmd == null || cmd.length == 0) continue;
                        var gicon = ai.get_icon();
                        if (gicon == null) continue;
                        string basename = GLib.Path.get_basename(cmd);
                        // Map both full path and basename
                        _cmd_to_icon.set(basename, gicon.to_string());
                        _cmd_to_icon.set(cmd, gicon.to_string());
                    }
                } catch {}
            }

            // Try direct match
            if (_cmd_to_icon.contains(name)) {
                icon = _cmd_to_icon.get(name);
            }

            // Try cmdline from /proc
            if (icon == "system-run-symbolic") {
                try {
                    string cmdline;
                    FileUtils.get_contents("/proc/%d/cmdline".printf(pid), out cmdline);
                    if (cmdline.length > 0) {
                        int null_pos = cmdline.index_of_char((uchar)'\0');
                        string exe = null_pos > 0 ? cmdline.substring(0, null_pos) : cmdline;
                        string basename = GLib.Path.get_basename(exe);
                        if (_cmd_to_icon.contains(basename))
                            icon = _cmd_to_icon.get(basename);
                        else if (_cmd_to_icon.contains(exe))
                            icon = _cmd_to_icon.get(exe);
                    }
                } catch {}
            }

            // Try stripping common prefixes
            if (icon == "system-run-symbolic" && name.has_prefix("singularity-")) {
                string short_name = name.substring(11);
                if (_cmd_to_icon.contains(short_name))
                    icon = _cmd_to_icon.get(short_name);
            }

            _icon_cache.set(name, icon);
            return icon;
        }

        private int count_cores() {
            int n = 0;
            try {
                string s;
                FileUtils.get_contents("/proc/stat", out s);
                foreach (var line in s.split("\n"))
                    if (line.has_prefix("cpu") && !line.has_prefix("cpu ")) n++;
            } catch {}
            return n.clamp(1, 128);
        }

        private void setup_styles() {
            var provider = new Gtk.CssProvider();
            provider.load_from_data(MONITOR_CSS.data);
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string MONITOR_CSS = """
/* System Monitor */

.monitor-card {
    background-color: @card_bg;
    border-radius: 14px;
    border: 1px solid alpha(@text_color, 0.07);
    min-height: 160px;
}

.monitor-card-title {
    font-size: 12px;
    font-weight: 600;
    opacity: 0.6;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.monitor-card-value {
    font-size: 18px;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
}

.monitor-card-sub {
    font-size: 11px;
    opacity: 0.5;
    font-variant-numeric: tabular-nums;
}

.monitor-chart-wrap {
    background: transparent;
}

.monitor-proc-view,
.monitor-proc-view listview,
.monitor-proc-view > listview {
    background-color: transparent;
}

.monitor-proc-view row {
    padding: 4px 8px;
    background-color: transparent;
}

.monitor-high {
    color: @error_color;
    font-weight: 700;
}

.monitor-med {
    color: @warning_color;
    font-weight: 600;
}

.monitor-vsep {
    min-width: 1px;
    background-color: alpha(@text_color, 0.07);
    margin-top: 0;
    margin-bottom: 0;
}
""";

        private string format_kb(ulong kb) {
            if (kb >= 1024 * 1024) return "%.1f GB".printf((double)kb / 1024 / 1024);
            if (kb >= 1024)        return "%.1f MB".printf((double)kb / 1024);
            return "%lu KB".printf(kb);
        }

        private ulong parse_kb(string line) {
            var parts = line.split(":");
            if (parts.length < 2) return 0;
            return (ulong)long.parse(parts[1].strip().split(" ")[0]);
        }

        private ulong get_hz() {
            return 100; // Assume HZ=100 (standard Linux)
        }

        private ulong get_uptime_ticks() {
            try {
                string s;
                FileUtils.get_contents("/proc/uptime", out s);
                double sec = double.parse(s.split(" ")[0]);
                return (ulong)(sec * 100);
            } catch { return 0; }
        }

    }

}
