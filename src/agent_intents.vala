namespace Singularity.Apps {

    internal class MonitorIntents : Object {

        private class Sample {
            public int pid;
            public string name;
            public string state;
            public uint uid;
            public uint64 ticks;
            public uint64 rss_kb;
            public string command;
        }

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static string? read(string path) {
            try {
                string s;
                FileUtils.get_contents(path, out s);
                return s;
            } catch (Error e) {
                return null;
            }
        }

        private static uint64[] cpu_times() {
            string? stat = read("/proc/stat");
            if (stat == null) return { 0, 0 };
            string[] f = stat.split("\n")[0].split(" ");
            uint64 total = 0;
            uint64 idle = 0;
            int n = 0;
            foreach (string v in f) {
                if (v == "" || v == "cpu") continue;
                uint64 x = uint64.parse(v);
                total += x;
                if (n == 3 || n == 4) idle += x;
                n++;
            }
            return { total, idle };
        }

        private static Gee.HashMap<int, Sample> scan() {
            var map = new Gee.HashMap<int, Sample>();
            Dir dir;
            try {
                dir = Dir.open("/proc");
            } catch (Error e) {
                return map;
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                int pid = int.parse(name);
                if (pid <= 0 || pid.to_string() != name) continue;
                string? stat = read("/proc/%d/stat".printf(pid));
                if (stat == null) continue;
                int open = stat.index_of_char('(');
                int close = stat.last_index_of_char(')');
                if (open < 0 || close < open) continue;
                string[] rest = stat.substring(close + 2).split(" ");
                if (rest.length < 22) continue;
                var s = new Sample();
                s.pid = pid;
                s.name = stat.substring(open + 1, close - open - 1);
                s.state = rest[0];
                s.ticks = uint64.parse(rest[11]) + uint64.parse(rest[12]);
                s.rss_kb = uint64.parse(rest[21]) * (Posix.sysconf(Posix._SC_PAGESIZE) / 1024);
                string? status = read("/proc/%d/status".printf(pid));
                if (status != null) {
                    foreach (string line in status.split("\n")) {
                        if (line.has_prefix("Uid:")) {
                            string[] u = line.substring(4).strip().replace("\t", " ").split(" ");
                            s.uid = (uint) uint64.parse(u[0]);
                        }
                    }
                }
                string? cmd = read("/proc/%d/cmdline".printf(pid));
                s.command = "";
                if (cmd != null && cmd.length > 0) {
                    var sb = new StringBuilder();
                    uint8[] raw = cmd.data;
                    foreach (uint8 c in raw) sb.append_c(c == 0 ? ' ' : (char) c);
                    s.command = sb.str.strip();
                    if (s.command.length > 200) s.command = s.command.substring(0, 200);
                }
                map[pid] = s;
            }
            return map;
        }

        private static async void wait(uint ms) {
            Timeout.add(ms, wait.callback);
            yield;
        }

        private static string user_name(uint uid) {
            unowned Posix.Passwd? pw = Posix.getpwuid((Posix.uid_t) uid);
            return pw != null ? pw.pw_name : uid.to_string();
        }

        private static void meminfo(out uint64 total, out uint64 available, out uint64 swap_total, out uint64 swap_free) {
            total = available = swap_total = swap_free = 0;
            string? m = read("/proc/meminfo");
            if (m == null) return;
            foreach (string line in m.split("\n")) {
                string[] kv = line.split(":");
                if (kv.length < 2) continue;
                uint64 v = uint64.parse(kv[1].strip().split(" ")[0]);
                switch (kv[0]) {
                    case "MemTotal": total = v; break;
                    case "MemAvailable": available = v; break;
                    case "SwapTotal": swap_total = v; break;
                    case "SwapFree": swap_free = v; break;
                }
            }
        }

        private static double mb(uint64 kb) {
            return Math.round(kb / 102.4) / 10.0;
        }

        private static async void overview(MonitorApp app, owned Singularity.AppIntentReply reply) {
            var a = cpu_times();
            yield wait(500);
            var b2 = cpu_times();
            double busy = b2[0] > a[0] ? 100.0 * ((b2[0] - a[0]) - (b2[1] - a[1])) / (b2[0] - a[0]) : 0;
            uint64 total, available, swap_total, swap_free;
            meminfo(out total, out available, out swap_total, out swap_free);
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("cpu_percent").add_double_value(Math.round(busy * 10) / 10);
            b.set_member_name("cpus").add_int_value(get_num_processors());
            string? load = read("/proc/loadavg");
            if (load != null) {
                string[] l = load.split(" ");
                b.set_member_name("load").begin_array();
                for (int i = 0; i < 3 && i < l.length; i++) b.add_double_value(double.parse(l[i]));
                b.end_array();
            }
            b.set_member_name("memory_total_mb").add_double_value(mb(total));
            b.set_member_name("memory_used_mb").add_double_value(mb(total - available));
            b.set_member_name("memory_percent").add_double_value(total > 0 ? Math.round(1000.0 * (total - available) / total) / 10 : 0);
            b.set_member_name("swap_total_mb").add_double_value(mb(swap_total));
            b.set_member_name("swap_used_mb").add_double_value(mb(swap_total - swap_free));
            string? up = read("/proc/uptime");
            if (up != null) b.set_member_name("uptime_seconds").add_int_value((int64) double.parse(up.split(" ")[0]));
            b.set_member_name("processes").add_int_value(scan().size);
            b.end_object();
            reply(b.get_root(), null);
        }

        private static async void processes(MonitorApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            var first = scan();
            var t0 = cpu_times();
            yield wait(500);
            var second = scan();
            var t1 = cpu_times();
            double span = (double) (t1[0] - t0[0]) / get_num_processors();
            string q = text(args, "query").casefold();
            string sort = text(args, "sort") == "memory" ? "memory" : "cpu";
            int64 limit = args.has_member("limit") ? args.get_int_member("limit").clamp(1, 100) : 10;
            var list = new Gee.ArrayList<Sample>();
            var cpu = new Gee.HashMap<int, double?>();
            foreach (var s in second.values) {
                if (q != "" && !s.name.casefold().contains(q) && !s.command.casefold().contains(q) && s.pid.to_string() != q) continue;
                var p = first[s.pid];
                double c = p != null && span > 0 ? 100.0 * (s.ticks - p.ticks) / span : 0;
                cpu[s.pid] = c;
                list.add(s);
            }
            list.sort((x, y) => {
                if (sort == "memory") return x.rss_kb == y.rss_kb ? 0 : (x.rss_kb > y.rss_kb ? -1 : 1);
                double cx = cpu[x.pid];
                double cy = cpu[y.pid];
                return cx == cy ? (x.rss_kb > y.rss_kb ? -1 : 1) : (cx > cy ? -1 : 1);
            });
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("sorted_by").add_string_value(sort);
            b.set_member_name("matches").add_int_value(list.size);
            b.set_member_name("processes").begin_array();
            int n = 0;
            foreach (var s in list) {
                if (n++ == limit) break;
                b.begin_object();
                b.set_member_name("pid").add_int_value(s.pid);
                b.set_member_name("name").add_string_value(s.name);
                b.set_member_name("user").add_string_value(user_name(s.uid));
                b.set_member_name("cpu_percent").add_double_value(Math.round(cpu[s.pid] * 10) / 10);
                b.set_member_name("memory_mb").add_double_value(mb(s.rss_kb));
                b.set_member_name("state").add_string_value(s.state);
                if (s.command != "") b.set_member_name("command").add_string_value(s.command);
                b.end_object();
            }
            b.end_array();
            b.end_object();
            reply(b.get_root(), null);
        }

        private static async void stop(MonitorApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            try {
                if (!args.has_member("pid")) throw new IOError.INVALID_ARGUMENT("give the pid; find it with monitor_processes");
                int pid = (int) args.get_int_member("pid");
                if (pid <= 1) throw new IOError.INVALID_ARGUMENT("pid %d cannot be stopped", pid);
                if (pid == Posix.getpid()) throw new IOError.INVALID_ARGUMENT("Monitor cannot stop itself");
                var procs = scan();
                var s = procs[pid];
                if (s == null) throw new IOError.NOT_FOUND("no process %d", pid);
                if (s.uid != Posix.getuid()) throw new IOError.PERMISSION_DENIED("%s belongs to %s", s.name, user_name(s.uid));
                string expected = text(args, "name");
                if (expected != "" && expected.casefold() != s.name.casefold()) {
                    throw new IOError.INVALID_ARGUMENT("pid %d is %s, not %s", pid, s.name, expected);
                }
                bool force = args.has_member("force") && args.get_boolean_member("force");
                if (Posix.kill((Posix.pid_t) pid, force ? Posix.Signal.KILL : Posix.Signal.TERM) != 0) {
                    throw new IOError.FAILED("%s", Posix.strerror(Posix.errno));
                }
                bool gone = false;
                for (int i = 0; i < 20 && !gone; i++) {
                    yield wait(100);
                    string? stat = read("/proc/%d/stat".printf(pid));
                    gone = stat == null || stat.substring(stat.last_index_of_char(')') + 2, 1) == "Z";
                }
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("pid").add_int_value(pid);
                b.set_member_name("name").add_string_value(s.name);
                b.set_member_name("signal").add_string_value(force ? "KILL" : "TERM");
                b.set_member_name("exited").add_boolean_value(gone);
                if (!gone) b.set_member_name("hint").add_string_value("still running after 2 seconds; force stops it at once");
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            }
        }

        internal static void install(MonitorApp app) {
            var agent = app.agent;
            agent.add_async_intent("monitor_overview", "How busy the computer is now: processor use, memory, swap, load and uptime.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    overview.begin(app, (owned) reply);
                });
            agent.add_async_intent("monitor_processes", "The running processes using the most processor (or memory when sort is memory), optionally filtered by name, command or pid.",
                "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"sort\":{\"type\":\"string\",\"enum\":[\"cpu\",\"memory\"]},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    processes.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("monitor_end_process", "End one of your processes by pid, asking it to quit; force kills it at once and loses unsaved work. name guards against a reused pid.",
                "{\"type\":\"object\",\"properties\":{\"pid\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"},\"force\":{\"type\":\"boolean\"}},\"required\":[\"pid\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    stop.begin(app, args, (owned) reply);
                });
        }
    }
}
