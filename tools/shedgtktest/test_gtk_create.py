"""create.start streams SSE progress through the pure shed-core CreateStore to a
complete shed; cancel drops it; a concurrent sheds.list doesn't deadlock."""

import time


def test_create_streams_to_complete(gtk):
    cid = gtk.create_start("new-shed", image="full")

    gtk.wait_until(
        lambda: gtk.create_status(cid).get("state") == "complete",
        timeout=15,
        what="create complete",
    )
    st = gtk.create_status(cid)
    assert st["state"] == "complete"
    assert st["shed"]["name"] == "new-shed"
    assert len(st["messages"]) >= 1  # progress messages streamed

    # the new shed shows up in the dashboard after a refresh
    gtk.sheds_refresh()
    assert "new-shed" in {r["name"] for r in gtk.dashboard_dump()}


def test_create_cancel_drops_it(gtk):
    cid = gtk.create_start("cancelme")
    gtk.create_cancel(cid)
    # cancel removes the store entry (whether or not it had completed)
    assert gtk.create_status(cid).get("state") == "unknown"


def test_sheds_list_during_create_no_deadlock(gtk):
    # A create in flight must not block sheds.list — independent tokio tasks.
    cid = gtk.create_start("concurrent")
    t0 = time.monotonic()
    sheds = gtk.sheds_list()
    assert time.monotonic() - t0 < 5, "sheds.list appears to have deadlocked during a create"
    assert isinstance(sheds, list)
    gtk.create_cancel(cid)
