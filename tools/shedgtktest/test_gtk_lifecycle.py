"""Lifecycle (start/stop/reset/delete) drives the server + the dashboard."""


def test_stop_start_delete(gtk):
    gtk.wait_until(lambda: len(gtk.sheds_list()) >= 2, what="sheds populated")

    # stop a running shed → sheds.list (live) reflects it
    gtk.shed_action("stop", "hello-world")
    gtk.wait_until(lambda: gtk.shed_status("hello-world") == "stopped", what="hello-world stopped")

    # start a stopped shed
    gtk.shed_action("start", "callbell")
    gtk.wait_until(lambda: gtk.shed_status("callbell") == "running", what="callbell running")

    # after a refresh, the UI-truth dashboard.dump reflects both
    gtk.sheds_refresh()
    dump = {r["name"]: r for r in gtk.dashboard_dump()}
    assert dump["hello-world"]["status"] == "stopped"
    assert dump["callbell"]["status"] == "running"

    # delete drops it from the server
    gtk.shed_action("delete", "callbell")
    gtk.wait_until(
        lambda: "callbell" not in {s["name"] for s in gtk.sheds_list()},
        what="callbell deleted",
    )
