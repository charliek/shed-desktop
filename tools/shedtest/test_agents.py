"""M2: the RC classifier is reachable over IPC, and launch/list/kill drive
the agents pane (in test mode against an in-memory session table)."""

from __future__ import annotations

import pytest

from client import ShedError


def test_classify_agent_ready(shed):
    pane = "·✔︎· Connected\nContinue at https://claude.ai/code?environment=env_01ABC"
    r = shed.rc_classify("claude-broker", pane)
    assert r["state"] == "ready"
    assert r["url"] == "https://claude.ai/code?environment=env_01ABC"


def test_classify_repl_needs_trust(shed):
    r = shed.rc_classify("claude-rc", "Quick safety check: Is this a project you trust?")
    assert r["state"] == "needs-trust"


def test_classify_agent_reconnecting(shed):
    r = shed.rc_classify("claude-broker", "·|· Reconnecting · retrying in 2.5s")
    assert r["state"] == "reconnecting"
    assert "url" not in r


def test_launch_list_kill(shed):
    shed.refresh()
    session = shed.rc_launch("hello-world", kind="claude-rc", display_name="demo")
    slug = session["slug"]
    assert session["state"] == "ready"
    assert session["url"].startswith("https://claude.ai/code/session_")
    assert session["kind"] == "claude-rc"

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
    session = shed.rc_launch("hello-world", kind="claude-broker")
    try:
        assert session["url"].startswith("https://claude.ai/code?environment=env_")
    finally:
        shed.rc_kill("hello-world", session["slug"])


def test_launch_carries_managed_provenance(shed):
    """A launched session is managed and stamps SHED_RC_* provenance, which
    survives the round-trip through rc.list (RC Session Convention v2)."""
    shed.refresh()
    session = shed.rc_launch("hello-world", kind="claude-rc", display_name="demo")
    slug = session["slug"]
    try:
        assert session["managed"] is True
        assert session["rc_id"]
        assert session["created_by"].startswith("shed-desktop/")
        assert session["created_at"].endswith("Z")
        listed = {s["slug"]: s for s in shed.rc_list()}
        assert listed[slug]["managed"] is True
        assert listed[slug]["created_by"] == session["created_by"]
        assert listed[slug]["rc_id"] == session["rc_id"]
    finally:
        shed.rc_kill("hello-world", slug)


def test_console_terminal_preview_attaches_session(shed):
    """The Agents console button resolves to `ssh … tmux attach -t rc-<slug>`,
    observable (without spawning) via terminal.preview with a session."""
    shed.refresh()
    session = shed.rc_launch("hello-world", kind="shell", display_name="dev")
    slug = session["slug"]
    try:
        prev = shed.terminal_preview("hello-world", host=session["host"],
                                     session=session["tmux_session"])
        assert prev["argv"][-4:] == ["tmux", "attach", "-t", f"rc-{slug}"]
        assert f"tmux attach -t rc-{slug}" in prev["command"]
    finally:
        shed.rc_kill("hello-world", slug)


def test_inject_legacy_session_renders(shed):
    """A legacy/unmanaged rc-* session lists with managed=false and renders the
    Agents pane (legacy badge + console button) for a screenshot."""
    shed.refresh()
    host = shed.host_list()[0]["name"]
    shed.rc_inject_test("hello-world", "legacy1", host=host, kind="claude-broker", state="ready")
    try:
        listed = {s["slug"]: s for s in shed.rc_list()}
        assert "legacy1" in listed
        assert listed["legacy1"]["managed"] is False
        shed.navigate("agents")
        shed.show_window()
        png, w, h = shed.screenshot(surface="window", scale=2)
        assert png[:8] == b"\x89PNG\r\n\x1a\n", "expected a PNG"
        assert w > 0 and h > 0
    finally:
        shed.rc_kill("hello-world", "legacy1", host=host)


def test_launch_sheet_is_screenshot_driveable(shed):
    shed.show_launch()
    png, w, h = shed.screenshot(surface="window", scale=2)
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "expected a PNG"
    assert w > 0 and h > 0


def test_launch_with_initial_prompt(shed):
    """rc.launch accepts an optional initial_prompt for the kinds that take typed
    input (claude-rc → prompt, shell → command)."""
    shed.refresh()
    rc = shed.rc_launch("hello-world", kind="claude-rc", display_name="demo",
                        initial_prompt="summarize this repo")
    try:
        assert rc["state"] == "ready"
        assert rc["kind"] == "claude-rc"
    finally:
        shed.rc_kill("hello-world", rc["slug"])

    sh = shed.rc_launch("hello-world", kind="shell", display_name="dev",
                        initial_prompt="npm install && npm test")
    try:
        assert sh["state"] == "ready"
        assert sh["kind"] == "shell"
    finally:
        shed.rc_kill("hello-world", sh["slug"])


def test_launch_rejects_control_char_prompt(shed):
    """A control char in initial_prompt is rejected before the test-mode branch.
    This also proves the custom RcLaunchParams decoder captured the field — were it
    dropped, validation would pass and no error would be raised."""
    shed.refresh()
    with pytest.raises(ShedError) as exc:
        shed.rc_launch("hello-world", kind="claude-rc", initial_prompt="bad\nvalue")
    assert exc.value.code == "invalid-param"


def test_launch_rejects_overlong_prompt(shed):
    shed.refresh()
    with pytest.raises(ShedError) as exc:
        shed.rc_launch("hello-world", kind="shell", initial_prompt="a" * 2001)
    assert exc.value.code == "invalid-param"


def test_launch_rejects_prompt_for_broker(shed):
    """claude-broker has no pane to type into, so a prompt is rejected (the guest
    rejects it too). Launching broker without a prompt stays valid (covered by
    test_launch_agent_kind_gets_environment_url)."""
    shed.refresh()
    with pytest.raises(ShedError) as exc:
        shed.rc_launch("hello-world", kind="claude-broker", initial_prompt="nope")
    assert exc.value.code == "invalid-param"
