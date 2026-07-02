"""dashboard.dump (the UI-truth op) + sheds.list return the fixture sheds."""


def test_dashboard_dump_matches_fixture(gtk):
    # The dashboard fetches on launch (async); wait for it to populate.
    gtk.wait_until(lambda: len(gtk.dashboard_dump()) >= 2, what="dashboard populated")
    rows = {r["name"]: r for r in gtk.dashboard_dump()}
    assert set(rows) == {"hello-world", "callbell"}
    assert rows["hello-world"]["status"] == "running"
    assert rows["callbell"]["status"] == "stopped"
    # shed-core stamps the configured server name as the host.
    assert all(r["host"] == "mock" for r in rows.values())


def test_sheds_list_matches_fixture(gtk):
    gtk.wait_until(lambda: len(gtk.sheds_list()) >= 2, what="sheds populated")
    names = sorted(s["name"] for s in gtk.sheds_list())
    assert names == ["callbell", "hello-world"]
