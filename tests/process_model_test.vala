using Singularity.Apps;

private void process_rows() {
    var model = new ProcessListModel();
    var procs = new Gee.ArrayList<ProcessInfo>();
    var first = new ProcessInfo();
    first.pid = 100;
    first.name = "browser";
    first.group_key = "browser";
    first.mem_kb = 1000;
    var second = new ProcessInfo();
    second.pid = 200;
    second.name = "browser";
    second.group_key = "browser";
    second.mem_kb = 2000;
    procs.add(first);
    procs.add(second);
    procs.add(first);
    model.update(procs, "");
    assert(model.get_n_items() == 1);
    var group = (ProcessGroup) model.get_item(0);
    assert(group.count == 2);
    assert(group.mem_kb == 3000);
    model.toggle_group(group);
    assert(model.get_n_items() == 3);
    model.update(procs, "");
    assert(model.get_n_items() == 3);
    model.grouped = false;
    model.update(procs, "");
    assert(model.get_n_items() == 2);
    assert(((ProcessInfo) model.get_item(0)).pid != ((ProcessInfo) model.get_item(1)).pid);
    model.update(procs, "200");
    assert(model.get_n_items() == 1);
    assert(((ProcessInfo) model.get_item(0)).pid == 200);
    second.group_key = "";
    second.name = "other";
    model.grouped = true;
    model.update(procs, "other");
    assert(model.get_n_items() == 1);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/monitor/process-rows", process_rows);
    return Test.run();
}
