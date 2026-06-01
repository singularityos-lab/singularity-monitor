using Gtk;
using GLib;
using Cairo;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    public class MemMapEntry : Object {
        public string addr  { get; set; default = ""; }
        public string size  { get; set; default = ""; }
        public string perms { get; set; default = ""; }
        public string name  { get; set; default = ""; }
    }

    public class FdEntry : Object {
        public string fd   { get; set; default = ""; }
        public string kind { get; set; default = ""; }
        public string path { get; set; default = ""; }
    }

    public class ProcessInfo : Object {
        public int    pid        { get; set; }
        public string name       { get; set; default = ""; }
        public string icon_name  { get; set; default = "system-run-symbolic"; }
        public string user       { get; set; default = ""; }
        public double cpu        { get; set; default = 0; }
        public ulong  mem_kb     { get; set; default = 0; }
        public string state      { get; set; default = ""; }
        public string group_key  { get; set; default = ""; }

        public ulong prev_utime  { get; set; default = 0; }
        public ulong prev_stime  { get; set; default = 0; }
    }

    /**
     * A group of processes sharing the same name.
     * Collapsed groups show aggregated CPU/memory; expanded groups
     * reveal individual ProcessInfo entries.
     */
    public class ProcessGroup : Object {
        public string name       { get; set; default = ""; }
        public string icon_name  { get; set; default = "system-run-symbolic"; }
        public int    count      { get; set; default = 0; }
        public double cpu        { get; set; default = 0; }
        public ulong  mem_kb     { get; set; default = 0; }
        public bool   expanded   { get; set; default = false; }
        public Gee.ArrayList<ProcessInfo> processes { get; private set; }

        public ProcessGroup(string name, string icon_name) {
            this.name = name;
            this.icon_name = icon_name;
            processes = new Gee.ArrayList<ProcessInfo>();
        }

        public void add(ProcessInfo p) {
            processes.add(p);
            count = processes.size;
            cpu += p.cpu;
            mem_kb += p.mem_kb;
        }

        public void recalc() {
            count = processes.size;
            cpu = 0;
            mem_kb = 0;
            foreach (var p in processes) {
                cpu += p.cpu;
                mem_kb += p.mem_kb;
            }
        }
    }

    /**
     * Flat list model that represents grouped/ungrouped processes.
     * Groups appear as expandable rows; individual processes appear
     * when their group is expanded (or when ungrouped).
     */
    public class ProcessListModel : Object, GLib.ListModel {
        private Gee.ArrayList<ProcessGroup> _groups = new Gee.ArrayList<ProcessGroup>();
        private Gee.HashMap<string, ProcessGroup> _group_map = new Gee.HashMap<string, ProcessGroup>();
        private Gee.ArrayList<Object> _flat = new Gee.ArrayList<Object>();
        private bool _grouped = true;
        private string _search = "";

        public bool grouped {
            get { return _grouped; }
            set {
                _grouped = value;
                rebuild();
            }
        }

        public string search {
            get { return _search; }
            set {
                _search = value;
                rebuild();
            }
        }

        public void update(Gee.ArrayList<ProcessInfo> procs, string search_text) {
            _search = search_text;
            _groups.clear();
            _group_map.clear();

            foreach (var p in procs) {
                if (!matches_search(p)) continue;
                if (_grouped && p.group_key != "") {
                    var g = _group_map.get(p.group_key);
                    if (g == null) {
                        g = new ProcessGroup(p.group_key, p.icon_name);
                        _group_map.set(p.group_key, g);
                        _groups.add(g);
                    }
                    g.add(p);
                }
            }

            rebuild();
        }

        private bool matches_search(ProcessInfo p) {
            if (_search == "") return true;
            string q = _search.down();
            string n = p.name.down();
            if (n.contains(q)) return true;
            if (p.pid.to_string().contains(q)) return true;
            return fuzzy_match(n, q);
        }

        private static bool fuzzy_match(string text, string query) {
            int ti = 0, qi = 0;
            while (ti < text.length && qi < query.length) {
                if (text[ti] == query[qi]) qi++;
                ti++;
            }
            return qi == query.length;
        }

        private void rebuild() {
            int old_n = (int)_flat.size;
            _flat.clear();

            if (_grouped) {
                // Sort groups by cpu desc
                _groups.sort((a, b) => {
                    if (b.cpu > a.cpu) return 1;
                    if (b.cpu < a.cpu) return -1;
                    return 0;
                });

                foreach (var g in _groups) {
                    if (g.count == 1) {
                        // Single-process group: show as flat entry
                        _flat.add(g.processes.get(0));
                    } else {
                        _flat.add(g);
                        if (g.expanded) {
                            g.processes.sort((a, b) => {
                                if (b.cpu > a.cpu) return 1;
                                if (b.cpu < a.cpu) return -1;
                                return 0;
                            });
                            foreach (var p in g.processes)
                                _flat.add(p);
                        }
                    }
                }
            } else {
                // Ungrouped: add all processes from all groups
                foreach (var g in _groups) {
                    foreach (var p in g.processes)
                        _flat.add(p);
                }
            }

            int new_n = (int)_flat.size;
            items_changed(0, old_n, new_n);
        }

        public void toggle_group(ProcessGroup g) {
            g.expanded = !g.expanded;
            rebuild();
        }

        public GLib.Object? get_object(uint position) {
            if (position < _flat.size) return _flat.get((int)position);
            return null;
        }

        public GLib.Type get_item_type() { return typeof(GLib.Object); }

        public uint get_n_items() { return (uint)_flat.size; }

        public GLib.Object? get_item(uint position) {
            return get_object(position);
        }
    }
}