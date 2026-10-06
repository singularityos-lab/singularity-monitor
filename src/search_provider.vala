using GLib;

namespace Singularity.Apps {

    public class MonitorSearchProvider : Singularity.SearchProviderService {
        private const int MAX_RESULTS = 5;
        private const uint SAMPLE_MS = 400;

        private weak MonitorApp app;
        private HashTable<string, ProcessInfo> found = new HashTable<string, ProcessInfo>(str_hash, str_equal);

        public MonitorSearchProvider(MonitorApp app) {
            this.app = app;
        }

        private static string? query_for(string[] terms) {
            if (terms.length < 2) return null;
            string prefix = terms[0].down();
            if (prefix != "process" && prefix != _("process").down()) return null;
            string query = string.joinv(" ", terms[1:terms.length]).strip().down();
            return query.length > 0 ? query : null;
        }

        private static bool matches(int pid, string query) {
            try {
                string comm;
                FileUtils.get_contents("/proc/%d/comm".printf(pid), out comm);
                if (comm.strip().down().contains(query)) return true;
                string cmdline;
                FileUtils.get_contents("/proc/%d/cmdline".printf(pid), out cmdline);
                return cmdline.length > 0 && Path.get_basename(cmdline).down().contains(query);
            } catch (Error e) {
                return false;
            }
        }

        private HashTable<int, ProcessInfo> scan(string query) {
            var procs = new HashTable<int, ProcessInfo>(null, null);
            ulong hz = app.get_hz();
            ulong uptime = app.get_uptime_ticks();
            try {
                var dir = Dir.open("/proc");
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    if (!entry[0].isdigit()) continue;
                    int pid = int.parse(entry);
                    if (entry != query && !matches(pid, query)) continue;
                    var info = app.read_process_info(pid, hz, uptime);
                    if (info != null) procs.insert(pid, info);
                }
            } catch (Error e) {
                warning("Process search: %s", e.message);
            }
            return procs;
        }

        public override async string[] get_initial_results(string[] terms, Cancellable? cancellable) throws Error {
            string? query = query_for(terms);
            if (query == null) return {};

            var first = scan(query);
            if (first.size() == 0) return {};
            Timeout.add(SAMPLE_MS, get_initial_results.callback);
            yield;
            var second = scan(query);

            double scale = (double) app.get_hz() * SAMPLE_MS / 1000.0 * (double) int.max(app.count_cores(), 1);
            var list = new GenericArray<ProcessInfo>();
            second.foreach((pid, info) => {
                var prev = first.lookup(pid);
                if (prev != null) {
                    ulong delta = (info.prev_utime + info.prev_stime) - (prev.prev_utime + prev.prev_stime);
                    info.cpu = ((double) delta / scale * 100.0).clamp(0, 100);
                }
                list.add(info);
            });
            list.sort((a, b) => {
                if (a.cpu != b.cpu) return a.cpu < b.cpu ? 1 : -1;
                if (a.mem_kb != b.mem_kb) return a.mem_kb < b.mem_kb ? 1 : -1;
                return 0;
            });

            found.remove_all();
            string[] ids = {};
            for (int i = 0; i < list.length && ids.length < MAX_RESULTS; i++) {
                string id = list[i].pid.to_string();
                found[id] = list[i];
                ids += id;
            }
            return ids;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas(string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            foreach (string id in ids) {
                var info = found[id];
                if (info == null) continue;
                var meta = new Singularity.SearchResultMeta(id, info.name);
                meta.description = _("PID %d, CPU %.1f%%, Memory %s").printf(
                    info.pid, info.cpu, app.format_kb(info.mem_kb));
                string icon = info.icon_name.has_suffix("-symbolic") ? "application-x-executable" : info.icon_name;
                meta.icon = Icon.new_for_string(icon);
                meta.add_action("end", _("End Process"), "process-stop-symbolic");
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result(string id, string[] terms,
                                                                                uint32 timestamp) throws Error {
            app.show_process(int.parse(id), false);
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action(string id, string action_id,
                                                                                string[] terms, uint32 timestamp) throws Error {
            if (action_id == "end") app.show_process(int.parse(id), true);
            return null;
        }

        public override void launch_search(string[] terms, uint32 timestamp) {
            app.show_search(query_for(terms) ?? string.joinv(" ", terms));
        }
    }
}
