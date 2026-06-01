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


def test_server_field_propagates(shed, fake):
    # #21 multi-server: a server-tagged request carries `server` through the
    # queue and into the app-side audit entry.
    rid = fake.emit_request("ssh-agent", "sign", "srv-shed", "ssh-ed25519", server="mini3")
    shed.wait_until(lambda: rid in _pending_ids(shed), what="request queued")
    req = next((a for a in shed.approvals_list() if a["id"] == rid), None)
    assert req and req.get("server") == "mini3"
    shed.approval_decide(rid, "approve")
    assert fake.wait_response(rid)["decision"] == "approve"
    shed.wait_until(lambda: rid not in _pending_ids(shed), what="request resolved")
    entry = next((e for e in shed.activity_list() if e["id"] == rid), None)
    assert entry and entry.get("server") == "mini3"


def test_always_allow_persists_per_shed_rule(shed, fake):
    # "Always allow" approves now AND installs a per-shed approve rule, so the
    # next request for that shed is auto-approved by policy (no prompt).
    rid1 = fake.emit_request("ssh-agent", "sign", "always-shed", "ssh-ed25519")
    shed.wait_until(lambda: rid1 in _pending_ids(shed), what="first request queued")
    shed.approval_decide(rid1, "approve", always=True)
    assert fake.wait_response(rid1)["decision"] == "approve"
    assert any(r.get("scope") == "shed" and r.get("shed") == "always-shed" and r.get("action") == "approve"
               for r in shed.policy_list())
    rid2 = fake.emit_request("ssh-agent", "sign", "always-shed")
    resp2 = fake.wait_response(rid2)
    assert resp2 and resp2["decision"] == "approve" and resp2["decided_by"] == "policy"
    assert rid2 not in _pending_ids(shed)


def test_event_stream_covers_all_namespaces(shed, fake):
    fake.emit_event("aws-credentials", "get_credentials", "evt-shed", result="ok", approval="none")
    shed.wait_until(
        lambda: any(e["ns"] == "aws-credentials" and e["shed"] == "evt-shed" for e in shed.activity_list()),
        what="aws event in activity feed")


def test_notification_posted_and_invoked(shed, fake):
    # A prompt posts an actionable notification; driving its Approve action
    # resolves the request over the UDS, then the notification is withdrawn.
    rid = fake.emit_request("ssh-agent", "sign", "notif-shed", "ssh-ed25519")
    shed.wait_until(lambda: rid in _pending_ids(shed), what="request queued")
    shed.wait_until(lambda: any(n["id"] == rid for n in shed.notifications_list()),
                    what="notification posted")
    shed.notification_invoke(rid, "approve")
    resp = fake.wait_response(rid)
    assert resp and resp["decision"] == "approve"
    shed.wait_until(lambda: all(n["id"] != rid for n in shed.notifications_list()),
                    what="notification withdrawn")
    assert rid not in _pending_ids(shed)


def test_notification_not_posted_for_auto_policy(shed, fake):
    # An auto-approve never prompts, so it never posts a notification.
    shed.policy_set([{"scope": "default", "action": "approve", "gate": "none"}])
    rid = fake.emit_request("ssh-agent", "sign", "notif-auto-shed")
    assert fake.wait_response(rid)["decision"] == "approve"
    assert all(n["id"] != rid for n in shed.notifications_list())


def test_per_server_shed_isolation(shed, fake):
    # #21: a per-(server,shed) rule applies only to its own server, even when
    # the shed name is identical on another server.
    shed.policy_set([
        {"scope": "default", "action": "prompt", "gate": "touchid"},
        {"scope": "shed", "server": "mini3", "shed": "dual", "action": "approve", "gate": "none"},
    ])
    rid_a = fake.emit_request("ssh-agent", "sign", "dual", server="mini3")
    resp_a = fake.wait_response(rid_a)
    assert resp_a and resp_a["decision"] == "approve" and resp_a["decided_by"] == "policy"
    # Same shed name on a different server is NOT covered → it prompts (queues).
    rid_b = fake.emit_request("ssh-agent", "sign", "dual", server="studio")
    shed.wait_until(lambda: rid_b in _pending_ids(shed), what="other-server request queued")
    # Don't leak a pending request (+ its notification) into later tests.
    shed.approval_decide(rid_b, "deny")
    shed.wait_until(lambda: rid_b not in _pending_ids(shed), what="request resolved")


def test_audit_log_path_exposed(shed):
    # FR-6: the append-only audit log path is discoverable (the Activity pane's
    # "Reveal log" reveals this file).
    path = shed.activity_log_path()
    assert path.endswith("audit.jsonl")


def test_expiry_fails_closed(shed, fake):
    rid = fake.emit_request("ssh-agent", "sign", "expire-shed", expires_in_s=1.0)
    shed.wait_until(lambda: rid in _pending_ids(shed), what="request queued")
    resp = fake.wait_response(rid, timeout=8)  # left undecided → auto-deny on expiry
    assert resp and resp["decision"] == "deny" and resp["decided_by"] == "timeout"
    assert rid not in _pending_ids(shed)
