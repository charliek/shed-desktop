"""M3: the approval gate end-to-end against the fake host agent — policy
matrix, approve/deny round-trip, session grants, the all-namespace event
feed, and fail-closed expiry.

Each test uses a distinct shed name so session grants (4h, app-side state)
don't leak across tests.
"""

from __future__ import annotations


def _pending_ids(shed) -> set[str]:
    return {a["id"] for a in shed.approvals_list()}


def test_app_connected_to_host_agent(fake):
    assert fake.wait_connected()


def test_prompt_then_approve(shed, fake):
    rid = fake.emit_request("ssh-agent", "sign", "appr-shed", "ssh-ed25519")
    shed.wait_until(lambda: rid in _pending_ids(shed), what="request queued")
    shed.approval_decide(rid, "approve")
    resp = fake.wait_response(rid)
    assert resp and resp["decision"] == "approve"
    shed.wait_until(lambda: rid not in _pending_ids(shed), what="request resolved")
    entry = next((e for e in shed.activity_list() if e["id"] == rid), None)
    assert entry and entry["source"] == "app" and entry["result"] == "ok"
    assert entry["approval"] == "shed-desktop"


def test_prompt_then_deny(shed, fake):
    rid = fake.emit_request("ssh-agent", "sign", "deny-shed")
    shed.wait_until(lambda: rid in _pending_ids(shed), what="request queued")
    shed.approval_decide(rid, "deny")
    resp = fake.wait_response(rid)
    assert resp and resp["decision"] == "deny"


def test_policy_auto_approve(shed, fake):
    shed.policy_set([{"scope": "default", "action": "approve", "gate": "none"}])
    rid = fake.emit_request("ssh-agent", "sign", "auto-shed")
    resp = fake.wait_response(rid)
    assert resp and resp["decision"] == "approve" and resp["decided_by"] == "policy"
    assert rid not in _pending_ids(shed)  # never queued


def test_policy_auto_deny(shed, fake):
    shed.policy_set([{"scope": "default", "action": "deny", "gate": "none"}])
    rid = fake.emit_request("ssh-agent", "sign", "block-shed")
    resp = fake.wait_response(rid)
    assert resp and resp["decision"] == "deny" and resp["decided_by"] == "policy"


def test_session_grant_auto_approves_next(shed, fake):
    rid1 = fake.emit_request("ssh-agent", "sign", "grant-shed")
    shed.wait_until(lambda: rid1 in _pending_ids(shed), what="first request queued")
    shed.approval_decide(rid1, "approve", grant_session=True)
    assert fake.wait_response(rid1)["decision"] == "approve"
    # A second request for the same namespace+shed is auto-approved by the grant.
    rid2 = fake.emit_request("ssh-agent", "sign", "grant-shed")
    resp2 = fake.wait_response(rid2)
    assert resp2 and resp2["decision"] == "approve" and resp2["decided_by"] == "policy"
    assert rid2 not in _pending_ids(shed)


def test_event_stream_covers_all_namespaces(shed, fake):
    fake.emit_event("aws-credentials", "get_credentials", "evt-shed", result="ok", approval="none")
    shed.wait_until(
        lambda: any(e["ns"] == "aws-credentials" and e["shed"] == "evt-shed" for e in shed.activity_list()),
        what="aws event in activity feed")


def test_expiry_fails_closed(shed, fake):
    rid = fake.emit_request("ssh-agent", "sign", "expire-shed", expires_in_s=1.0)
    shed.wait_until(lambda: rid in _pending_ids(shed), what="request queued")
    resp = fake.wait_response(rid, timeout=8)  # left undecided → auto-deny on expiry
    assert resp and resp["decision"] == "deny" and resp["decided_by"] == "timeout"
    assert rid not in _pending_ids(shed)
