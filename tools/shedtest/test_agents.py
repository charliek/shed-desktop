"""M2: the RC classifier is reachable over IPC, and launch/list/kill drive
the agents pane (in test mode against an in-memory session table)."""

from __future__ import annotations


def test_classify_agent_ready(shed):
    pane = "·✔︎· Connected\nContinue at https://claude.ai/code?environment=env_01ABC"
    r = shed.rc_classify("agent", pane)
    assert r["state"] == "ready"
    assert r["url"] == "https://claude.ai/code?environment=env_01ABC"


def test_classify_repl_needs_trust(shed):
    r = shed.rc_classify("repl", "Quick safety check: Is this a project you trust?")
    assert r["state"] == "needs-trust"


def test_classify_agent_reconnecting(shed):
    r = shed.rc_classify("agent", "·|· Reconnecting · retrying in 2.5s")
    assert r["state"] == "reconnecting"
    assert "url" not in r


def test_launch_list_kill(shed):
    shed.refresh()
    session = shed.rc_launch("hello-world", kind="repl", display_name="demo")
    slug = session["slug"]
    assert session["state"] == "ready"
    assert session["url"].startswith("https://claude.ai/code/session_")
    assert session["kind"] == "repl"

    # It shows up in the list with its tmux name.
    listed = {s["slug"]: s for s in shed.rc_list()}
    assert slug in listed
    assert listed[slug]["tmux_session"] == f"rc-{slug}"

    # Kill removes it.
    shed.rc_kill("hello-world", slug)
    shed.wait_until(lambda: slug not in {s["slug"] for s in shed.rc_list()},
                    what="rc session gone")


def test_launch_agent_kind_gets_environment_url(shed):
    shed.refresh()
    session = shed.rc_launch("hello-world", kind="agent")
    try:
        assert session["url"].startswith("https://claude.ai/code?environment=env_")
    finally:
        shed.rc_kill("hello-world", session["slug"])
