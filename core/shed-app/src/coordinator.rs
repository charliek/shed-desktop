//! The approval coordinator — the security heart, ported from `AppModel`'s M3
//! section. A single-task mpsc **actor**: all of `pending`/`session_grants`/
//! `policy` mutate on one serialized task, reproducing the mac `@MainActor`
//! semantics. External callers send `Command`s over a channel; the actor
//! processes them one at a time.
//!
//! The gate (§2.2 crux): `decide_approval` NEVER awaits the `AuthGate` inline in
//! the actor — that would head-of-line-block the `Expire`/`Disconnect` commands
//! and let a decision persist a grant/rule from a prompt whose request already
//! expired (and was denied by the tick) or whose connection already dropped.
//! Instead it is two-phase: phase 1 validates + **spawns** the gate task; the
//! gate task re-enters the actor as `GateResolved`; phase 2 re-validates
//! presence + expiry (F4) and commits — mutate grants/rules, `respond`, audit,
//! clear — atomically in the actor. `respond` is the synchronous, non-blocking
//! `Responder` send, never awaited under state.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

use shed_core::approval::protocol::HostAgentInbound;
use shed_core::approval::{
    namespace, ttl_shorthand_seconds, ApprovalChoice, ApprovalDecision, ApprovalMethod,
    ApprovalRequest, ApprovalScope, AuditEntry, AuditSource, DecidedBy, PendingApprovalItem,
    PolicyAction, PolicyEngine, PolicyGate, PolicyRule, PolicyScope, SessionGrantKey,
    SshApprovalPolicy, DEFAULT_APPROVAL_TTL,
};

use crate::audit_store::AuditStore;
use crate::host_agent::HostAgentEvent;
use crate::traits::{
    AuthGateRef, AuthOutcome, AuthPrompt, ClockRef, NotifierRef, PostedNotification, ResponderRef,
};

/// Fallback grant duration (seconds) if even the default TTL can't parse.
const GRANT_TTL_FALLBACK_SECS: i64 = 2 * 3600;

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// A queued prompt: the request + the gate to apply when the user acts.
#[derive(Clone)]
struct PendingApproval {
    request: ApprovalRequest,
    gate: PolicyGate,
}

/// A session grant's expiry. `Sticky` = per-shed (never time-expires; lives until
/// restart or an SSH setting change). `Until` = per-session (unix seconds).
#[derive(Clone, Copy)]
enum GrantExpiry {
    Sticky,
    Until(i64),
}

/// The SSH approval preferences the coordinator rebuilds its policy from.
#[derive(Clone)]
pub struct SshPrefs {
    pub method: ApprovalMethod,
    pub policy: SshApprovalPolicy,
    pub ttl: String,
}

impl Default for SshPrefs {
    fn default() -> Self {
        Self {
            method: ApprovalMethod::BiometricsOrPassword,
            policy: SshApprovalPolicy::AlwaysAsk,
            ttl: DEFAULT_APPROVAL_TTL.to_string(),
        }
    }
}

/// The dependencies the coordinator owns (the platform seams + initial state).
pub struct CoordinatorDeps {
    pub responder: ResponderRef,
    pub notifier: NotifierRef,
    pub gate: AuthGateRef,
    pub clock: ClockRef,
    pub audit: AuditStore,
    pub ssh: SshPrefs,
    pub extra_rules: Vec<PolicyRule>,
    pub provider_modes: HashMap<String, ApprovalDecision>,
}

enum Command {
    Host(HostAgentEvent),
    Expire(Option<oneshot::Sender<()>>),
    Decide {
        id: String,
        choice: ApprovalChoice,
        reply: oneshot::Sender<()>,
    },
    GateResolved {
        id: String,
        choice: ApprovalChoice,
        outcome: AuthOutcome,
        reply: oneshot::Sender<()>,
    },
    SetSshApproval {
        method: Option<ApprovalMethod>,
        policy: Option<SshApprovalPolicy>,
        ttl: Option<String>,
        reply: oneshot::Sender<()>,
    },
    SetPolicyRules {
        rules: Vec<PolicyRule>,
        reply: oneshot::Sender<()>,
    },
    ApprovalsList(oneshot::Sender<Vec<PendingApprovalItem>>),
    ActivityList {
        limit: usize,
        reply: oneshot::Sender<Vec<AuditEntry>>,
    },
    PolicyList(oneshot::Sender<Vec<PolicyRule>>),
    NotificationsList(oneshot::Sender<Vec<PostedNotification>>),
    NotificationInvoke {
        id: String,
        decision: ApprovalDecision,
        reply: oneshot::Sender<bool>,
    },
    AuditLogPath(oneshot::Sender<String>),
    GateNamespaces(oneshot::Sender<Vec<String>>),
}

/// A cloneable handle to the coordinator actor. Every method sends a command and
/// (where a result is needed) awaits the reply.
#[derive(Clone)]
pub struct Coordinator {
    tx: mpsc::UnboundedSender<Command>,
}

impl Coordinator {
    /// Spawn the actor + a task forwarding host-agent events into it. Returns the
    /// handle. Call [`start_expiry_tick`](Self::start_expiry_tick) to drive the
    /// 1s expiry in production (tests drive `expire_now` deterministically).
    pub fn spawn(
        deps: CoordinatorDeps,
        host_events: mpsc::UnboundedReceiver<HostAgentEvent>,
    ) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut state = State {
            pending: HashMap::new(),
            session_grants: HashMap::new(),
            engine: PolicyEngine::new(vec![]),
            extra_rules: deps.extra_rules,
            ssh: deps.ssh,
            provider_modes: deps.provider_modes,
            gate_namespaces: Vec::new(),
            last_error: None,
            audit: deps.audit,
            responder: deps.responder,
            notifier: deps.notifier,
            gate: deps.gate,
            clock: deps.clock,
            self_tx: tx.clone(),
        };
        state.rebuild_policy(); // initial policy from prefs + extra rules

        let ftx = tx.clone();
        tokio::spawn(async move {
            let mut events = host_events;
            while let Some(ev) = events.recv().await {
                if ftx.send(Command::Host(ev)).is_err() {
                    break;
                }
            }
        });
        tokio::spawn(run(state, rx));
        Coordinator { tx }
    }

    /// Start the production 1s expiry tick.
    pub fn start_expiry_tick(&self) {
        let tx = self.tx.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                if tx.send(Command::Expire(None)).is_err() {
                    break;
                }
            }
        });
    }

    pub async fn decide_approval(&self, id: impl Into<String>, choice: ApprovalChoice) {
        let (reply, rx) = oneshot::channel();
        if self
            .tx
            .send(Command::Decide {
                id: id.into(),
                choice,
                reply,
            })
            .is_ok()
        {
            let _ = rx.await;
        }
    }

    /// Run the expiry sweep now and await it (deterministic tests).
    pub async fn expire_now(&self) {
        let (reply, rx) = oneshot::channel();
        if self.tx.send(Command::Expire(Some(reply))).is_ok() {
            let _ = rx.await;
        }
    }

    pub async fn set_ssh_approval(
        &self,
        method: Option<ApprovalMethod>,
        policy: Option<SshApprovalPolicy>,
        ttl: Option<String>,
    ) {
        let (reply, rx) = oneshot::channel();
        if self
            .tx
            .send(Command::SetSshApproval {
                method,
                policy,
                ttl,
                reply,
            })
            .is_ok()
        {
            let _ = rx.await;
        }
    }

    pub async fn set_policy_rules(&self, rules: Vec<PolicyRule>) {
        let (reply, rx) = oneshot::channel();
        if self
            .tx
            .send(Command::SetPolicyRules { rules, reply })
            .is_ok()
        {
            let _ = rx.await;
        }
    }

    pub async fn approvals_list(&self) -> Vec<PendingApprovalItem> {
        self.request(Command::ApprovalsList)
            .await
            .unwrap_or_default()
    }

    pub async fn activity_list(&self, limit: usize) -> Vec<AuditEntry> {
        let (reply, rx) = oneshot::channel();
        if self.tx.send(Command::ActivityList { limit, reply }).is_ok() {
            rx.await.unwrap_or_default()
        } else {
            Vec::new()
        }
    }

    pub async fn policy_list(&self) -> Vec<PolicyRule> {
        self.request(Command::PolicyList).await.unwrap_or_default()
    }

    pub async fn notifications_list(&self) -> Vec<PostedNotification> {
        self.request(Command::NotificationsList)
            .await
            .unwrap_or_default()
    }

    pub async fn notification_invoke(
        &self,
        id: impl Into<String>,
        decision: ApprovalDecision,
    ) -> bool {
        let (reply, rx) = oneshot::channel();
        if self
            .tx
            .send(Command::NotificationInvoke {
                id: id.into(),
                decision,
                reply,
            })
            .is_ok()
        {
            rx.await.unwrap_or(false)
        } else {
            false
        }
    }

    pub async fn audit_log_path(&self) -> String {
        self.request(Command::AuditLogPath)
            .await
            .unwrap_or_default()
    }

    pub async fn gate_namespaces(&self) -> Vec<String> {
        self.request(Command::GateNamespaces)
            .await
            .unwrap_or_default()
    }

    async fn request<T>(&self, make: impl FnOnce(oneshot::Sender<T>) -> Command) -> Option<T> {
        let (reply, rx) = oneshot::channel();
        if self.tx.send(make(reply)).is_ok() {
            rx.await.ok()
        } else {
            None
        }
    }
}

struct State {
    pending: HashMap<String, PendingApproval>,
    session_grants: HashMap<SessionGrantKey, GrantExpiry>,
    engine: PolicyEngine,
    extra_rules: Vec<PolicyRule>,
    ssh: SshPrefs,
    provider_modes: HashMap<String, ApprovalDecision>,
    gate_namespaces: Vec<String>,
    last_error: Option<String>,
    audit: AuditStore,
    responder: ResponderRef,
    notifier: NotifierRef,
    gate: AuthGateRef,
    clock: ClockRef,
    self_tx: mpsc::UnboundedSender<Command>,
}

async fn run(mut state: State, mut rx: mpsc::UnboundedReceiver<Command>) {
    while let Some(cmd) = rx.recv().await {
        match cmd {
            Command::Host(ev) => state.handle_host_event(ev),
            Command::Expire(reply) => {
                state.expire_pending();
                if let Some(r) = reply {
                    let _ = r.send(());
                }
            }
            Command::Decide { id, choice, reply } => state.begin_decide(id, choice, reply),
            Command::GateResolved {
                id,
                choice,
                outcome,
                reply,
            } => {
                state.finish_decide(&id, &choice, &outcome);
                let _ = reply.send(());
            }
            Command::SetSshApproval {
                method,
                policy,
                ttl,
                reply,
            } => {
                state.set_ssh_approval(method, policy, ttl);
                let _ = reply.send(());
            }
            Command::SetPolicyRules { rules, reply } => {
                state.engine = PolicyEngine::new(rules);
                let _ = reply.send(());
            }
            Command::ApprovalsList(reply) => {
                let _ = reply.send(state.sorted_items());
            }
            Command::ActivityList { limit, reply } => {
                let _ = reply.send(state.audit.recent(limit));
            }
            Command::PolicyList(reply) => {
                let _ = reply.send(state.engine.rules.clone());
            }
            Command::NotificationsList(reply) => {
                let _ = reply.send(state.notifier.posted());
            }
            Command::NotificationInvoke {
                id,
                decision,
                reply,
            } => {
                let exists = state.notifier.posted().iter().any(|n| n.id == id);
                if exists {
                    // Drive a decide through the same two-phase path (mirrors the
                    // mac notifier.onAction). Fire-and-forget; the caller polls the
                    // response, as the harness does.
                    let (r, _rx) = oneshot::channel();
                    let _ = state.self_tx.send(Command::Decide {
                        id,
                        choice: ApprovalChoice {
                            decision,
                            scope: None,
                            ttl: None,
                            persist: false,
                        },
                        reply: r,
                    });
                }
                let _ = reply.send(exists);
            }
            Command::AuditLogPath(reply) => {
                let _ = reply.send(state.audit.path().to_string_lossy().to_string());
            }
            Command::GateNamespaces(reply) => {
                let _ = reply.send(state.gate_namespaces.clone());
            }
        }
    }
}

impl State {
    fn handle_host_event(&mut self, ev: HostAgentEvent) {
        match ev {
            HostAgentEvent::Connected(ack) => self.gate_namespaces = ack.gate_namespaces,
            HostAgentEvent::Disconnected => {
                // F3: in-flight requests are dead (the agent fails closed on its
                // side); drop them so the user can't act on / persist a rule from a
                // stale prompt.
                let ids: Vec<String> = self.pending.keys().cloned().collect();
                for id in &ids {
                    self.notifier.withdraw(id);
                }
                self.pending.clear();
            }
            HostAgentEvent::Frame(frame) => match *frame {
                HostAgentInbound::ApprovalRequest(req) => self.handle_approval_request(req),
                HostAgentInbound::Event(evt) => {
                    let entry =
                        AuditEntry::from_event_frame(evt, new_id(), self.clock.now_iso8601());
                    self.audit.append(entry);
                }
                _ => {}
            },
        }
    }

    fn handle_approval_request(&mut self, req: ApprovalRequest) {
        let decision = self.engine.decide(&req, &self.valid_grants());
        match decision.action {
            PolicyAction::Approve => self.respond_and_audit(
                &req,
                ApprovalDecision::Approve,
                DecidedBy::Policy,
                decision.applied_scope.wire(),
                "",
                "",
            ),
            PolicyAction::Deny => self.respond_and_audit(
                &req,
                ApprovalDecision::Deny,
                DecidedBy::Policy,
                decision.applied_scope.wire(),
                "",
                "",
            ),
            PolicyAction::Prompt => {
                self.notifier.post(&req);
                self.pending.insert(
                    req.id.clone(),
                    PendingApproval {
                        request: req,
                        gate: decision.gate,
                    },
                );
            }
        }
    }

    /// Phase 1 of a user decision. Validate + (if a biometric gate applies)
    /// spawn the gate WITHOUT awaiting it in the actor — it re-enters as
    /// `GateResolved`. Otherwise commit directly.
    fn begin_decide(&mut self, id: String, choice: ApprovalChoice, reply: oneshot::Sender<()>) {
        let Some(item) = self.pending.get(&id).cloned() else {
            let _ = reply.send(());
            return;
        };
        // F4 pre-gate: don't act on an already-expired request (the 1s tick may
        // not have fired yet, but acting now would send a late decision / grant).
        if !self.not_expired(&item.request) {
            let _ = reply.send(());
            return;
        }
        if choice.decision == ApprovalDecision::Approve && item.gate.is_biometric() {
            let prompt = AuthPrompt {
                reason: format!(
                    "Approve {} {} for shed {}",
                    item.request.namespace, item.request.op, item.request.shed
                ),
                biometrics_only: item.gate == PolicyGate::Biometrics,
            };
            let gate = self.gate.clone();
            let tx = self.self_tx.clone();
            tokio::spawn(async move {
                let outcome = gate.gate(prompt).await;
                let _ = tx.send(Command::GateResolved {
                    id,
                    choice,
                    outcome,
                    reply,
                });
            });
        } else {
            // No gate (prompt/none) or a deny — commit directly, no await.
            self.finish_decide(&id, &choice, &AuthOutcome::Approved);
            let _ = reply.send(());
        }
    }

    /// Phase 2 — runs in the actor after the gate resolves (or directly for the
    /// no-gate path). Re-validates presence + expiry (F4 post-gate), then commits.
    fn finish_decide(&mut self, id: &str, choice: &ApprovalChoice, outcome: &AuthOutcome) {
        // F4 post-gate: the request may have expired (and been denied by the tick)
        // or been dropped (disconnect) while the gate was up.
        let Some(item) = self.pending.get(id).cloned() else {
            return; // gone -> no late decision
        };
        if !self.not_expired(&item.request) {
            return;
        }
        let req = &item.request;
        let decision = choice.decision;
        // A biometric approve honors the gate outcome; a non-Approved outcome
        // leaves the request pending (mac-parity — retry or expire), surfacing why.
        if decision == ApprovalDecision::Approve
            && item.gate.is_biometric()
            && *outcome != AuthOutcome::Approved
        {
            self.last_error = Some(format!("auth not confirmed for {}: {outcome:?}", req.shed));
            return;
        }
        let decided_by = if decision == ApprovalDecision::Approve && item.gate.is_biometric() {
            DecidedBy::Touchid
        } else {
            DecidedBy::User
        };
        let grant_key =
            SessionGrantKey::new(req.server.clone(), req.namespace.clone(), req.shed.clone());
        // F7: any deny supersedes a live session grant.
        if decision == ApprovalDecision::Deny {
            self.session_grants.remove(&grant_key);
        }

        let mut sent_scope = choice
            .scope
            .map(|s| s.wire().to_string())
            .unwrap_or_else(|| "per-request".to_string());
        let mut sent_ttl = String::new();
        let mut policy_label = "manual".to_string();
        if choice.persist {
            // Always-allow (approve) / always-deny (deny) — a per-shed rule.
            self.add_shed_rule(&req.server, &req.shed, decision);
            sent_scope = "always".to_string();
            policy_label = if decision == ApprovalDecision::Approve {
                "shed-rule".to_string()
            } else {
                "deny-rule".to_string()
            };
        } else if decision == ApprovalDecision::Approve {
            if let Some(scope) = choice.scope {
                if scope == ApprovalScope::PerShed {
                    // Sticky: asks once per shed, then auto-approves until restart /
                    // an SSH setting change. TTL is irrelevant.
                    self.session_grants.insert(grant_key, GrantExpiry::Sticky);
                    policy_label = "session-grant".to_string();
                } else if scope == ApprovalScope::PerSession {
                    // Resolve one validated TTL (empty/invalid -> default) and use it
                    // for BOTH the grant expiry and the value reported to the host.
                    let ttl_text = choice
                        .ttl
                        .as_deref()
                        .filter(|t| ttl_shorthand_seconds(t).is_some())
                        .unwrap_or(DEFAULT_APPROVAL_TTL);
                    let secs = ttl_shorthand_seconds(ttl_text).unwrap_or(GRANT_TTL_FALLBACK_SECS);
                    self.session_grants
                        .insert(grant_key, GrantExpiry::Until(self.clock.now_unix() + secs));
                    sent_ttl = ttl_text.to_string();
                    policy_label = "session-grant".to_string();
                }
            }
        }

        self.respond_and_audit(
            req,
            decision,
            decided_by,
            &policy_label,
            &sent_scope,
            &sent_ttl,
        );
        self.pending.remove(id);
        self.notifier.withdraw(id);
    }

    fn expire_pending(&mut self) {
        let now = self.clock.now_unix();
        let expired: Vec<ApprovalRequest> = self
            .pending
            .values()
            .map(|p| p.request.clone())
            .filter(|r| self.expired_by_tick(r, now))
            .collect();
        for req in &expired {
            self.respond_and_audit(
                req,
                ApprovalDecision::Deny,
                DecidedBy::Timeout,
                "expired",
                "",
                "",
            );
            self.pending.remove(&req.id);
            self.notifier.withdraw(&req.id);
        }
    }

    fn respond_and_audit(
        &mut self,
        req: &ApprovalRequest,
        decision: ApprovalDecision,
        decided_by: DecidedBy,
        policy: &str,
        scope: &str,
        ttl: &str,
    ) {
        // Record BEFORE transmitting, so an approve we sent always has a trail
        // (F9). Best-effort: an audit-write failure must not block the respond.
        self.audit.append(AuditEntry {
            id: req.id.clone(),
            ts: self.clock.now_iso8601(),
            source: AuditSource::App,
            server: (!req.server.is_empty()).then(|| req.server.clone()),
            shed: Some(req.shed.clone()),
            ns: Some(req.namespace.clone()),
            op: Some(req.op.clone()),
            result: if decision == ApprovalDecision::Approve {
                "ok".to_string()
            } else {
                "denied".to_string()
            },
            detail: Some(req.detail.clone()),
            code: None,
            reason: None,
            approval: Some("shed-desktop".to_string()),
            policy: Some(policy.to_string()),
        });
        self.responder.respond(
            &req.id,
            decision,
            decided_by,
            (!scope.is_empty()).then_some(scope),
            (!ttl.is_empty()).then_some(ttl),
        );
    }

    /// Re-decide queued prompts against the current policy — after a policy change
    /// a card queued under an old prompting policy must resolve now rather than
    /// linger under a non-prompting policy. Prompts stay put.
    fn reevaluate_pending(&mut self) {
        let grants = self.valid_grants();
        let ids: Vec<String> = self.pending.keys().cloned().collect();
        for id in ids {
            let Some(item) = self.pending.get(&id).cloned() else {
                continue;
            };
            let decision = self.engine.decide(&item.request, &grants);
            if decision.action == PolicyAction::Prompt {
                continue;
            }
            let d = if decision.action == PolicyAction::Approve {
                ApprovalDecision::Approve
            } else {
                ApprovalDecision::Deny
            };
            self.respond_and_audit(
                &item.request,
                d,
                DecidedBy::Policy,
                decision.applied_scope.wire(),
                "",
                "",
            );
            self.pending.remove(&id);
            self.notifier.withdraw(&id);
        }
    }

    fn set_ssh_approval(
        &mut self,
        method: Option<ApprovalMethod>,
        policy: Option<SshApprovalPolicy>,
        ttl: Option<String>,
    ) {
        if let Some(m) = method {
            self.ssh.method = m;
        }
        if let Some(p) = policy {
            self.ssh.policy = p;
        }
        if let Some(t) = ttl {
            self.ssh.ttl = t;
        }
        self.rebuild_policy();
        self.reset_ssh_grants();
        self.reevaluate_pending();
    }

    fn rebuild_policy(&mut self) {
        let ssh = self.ssh.policy;
        let ssh_gate = if ssh.prompts() {
            self.ssh.method.gate()
        } else {
            PolicyGate::None
        };
        let mut rules = vec![
            PolicyRule {
                scope: PolicyScope::Namespace,
                server: None,
                namespace: Some(namespace::SSH.to_string()),
                shed: None,
                action: ssh.namespace_action(),
                gate: ssh_gate,
            },
            PolicyRule {
                scope: PolicyScope::Namespace,
                server: None,
                namespace: Some(namespace::AWS.to_string()),
                shed: None,
                action: self.provider_mode(namespace::AWS).policy_action(),
                gate: PolicyGate::None,
            },
            PolicyRule {
                scope: PolicyScope::Namespace,
                server: None,
                namespace: Some(namespace::DOCKER.to_string()),
                shed: None,
                action: self.provider_mode(namespace::DOCKER).policy_action(),
                gate: PolicyGate::None,
            },
        ];
        rules.extend(self.extra_rules.iter().cloned());
        self.engine = PolicyEngine::new(rules);
    }

    fn provider_mode(&self, ns: &str) -> ApprovalDecision {
        self.provider_modes
            .get(ns)
            .copied()
            .unwrap_or(ApprovalDecision::Deny)
    }

    fn reset_ssh_grants(&mut self) {
        self.session_grants
            .retain(|k, _| k.namespace != namespace::SSH);
    }

    /// Store the server verbatim — `""` (single/unnamed server) is NOT collapsed
    /// to `None`, so a single-server grant never silently widens (F12).
    fn add_shed_rule(&mut self, server: &str, shed: &str, action: ApprovalDecision) {
        self.extra_rules.retain(|r| {
            !(r.scope == PolicyScope::Shed
                && r.shed.as_deref() == Some(shed)
                && r.server.as_deref().unwrap_or("") == server)
        });
        self.extra_rules.push(PolicyRule {
            scope: PolicyScope::Shed,
            server: Some(server.to_string()),
            namespace: None,
            shed: Some(shed.to_string()),
            action: action.policy_action(),
            gate: PolicyGate::None,
        });
        self.rebuild_policy();
    }

    fn valid_grants(&self) -> HashSet<SessionGrantKey> {
        let now = self.clock.now_unix();
        self.session_grants
            .iter()
            .filter(|(_, e)| match e {
                GrantExpiry::Sticky => true,
                GrantExpiry::Until(t) => *t > now,
            })
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// True if the request is still valid to act on. Unparseable/absent expiry ->
    /// treated as ALREADY expired (fail-closed; matches the mac `?? .distantPast`
    /// on the approve path).
    fn not_expired(&self, req: &ApprovalRequest) -> bool {
        crate::timefmt::parse_unix(&req.expires_at)
            .map(|e| e > self.clock.now_unix())
            .unwrap_or(false)
    }

    /// True if the 1s tick should expire-to-deny this. Unparseable/absent -> NOT
    /// expired by the tick (matches the mac `?? now`: the request can't be
    /// approved either, so it lingers until disconnect).
    fn expired_by_tick(&self, req: &ApprovalRequest, now: i64) -> bool {
        crate::timefmt::parse_unix(&req.expires_at)
            .map(|e| e < now)
            .unwrap_or(false)
    }

    fn sorted_items(&self) -> Vec<PendingApprovalItem> {
        let scope = self
            .ssh
            .policy
            .default_scope()
            .unwrap_or(ApprovalScope::PerRequest);
        let ttl = self.ssh.ttl.clone();
        let mut items: Vec<&PendingApproval> = self.pending.values().collect();
        items.sort_by(|a, b| a.request.expires_at.cmp(&b.request.expires_at));
        items
            .into_iter()
            .map(|p| PendingApprovalItem::new(p.request.clone(), p.gate, scope, ttl.clone()))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{AlwaysApprovedGate, FakeNotifier};
    use crate::traits::{AuthGate, Clock, Responder};
    use std::sync::atomic::{AtomicI64, Ordering};
    use std::sync::{Arc, Mutex};
    use tokio::sync::Notify;

    // -- test doubles --------------------------------------------------------

    struct TestClock {
        now: Arc<AtomicI64>,
    }
    impl Clock for TestClock {
        fn now_unix(&self) -> i64 {
            self.now.load(Ordering::SeqCst)
        }
    }
    #[derive(Clone)]
    struct ClockHandle {
        now: Arc<AtomicI64>,
    }
    impl ClockHandle {
        fn new(at: i64) -> (ClockRef, ClockHandle) {
            let now = Arc::new(AtomicI64::new(at));
            (
                Arc::new(TestClock { now: now.clone() }),
                ClockHandle { now },
            )
        }
        fn set(&self, v: i64) {
            self.now.store(v, Ordering::SeqCst);
        }
    }

    #[derive(Clone)]
    struct RespondCall {
        decision: ApprovalDecision,
        decided_by: DecidedBy,
        scope: Option<String>,
        ttl: Option<String>,
    }
    #[derive(Default)]
    struct FakeResponder {
        calls: Mutex<Vec<RespondCall>>,
    }
    impl Responder for FakeResponder {
        fn respond(
            &self,
            _request_id: &str,
            decision: ApprovalDecision,
            decided_by: DecidedBy,
            scope: Option<&str>,
            ttl: Option<&str>,
        ) {
            self.calls.lock().unwrap().push(RespondCall {
                decision,
                decided_by,
                scope: scope.map(Into::into),
                ttl: ttl.map(Into::into),
            });
        }
    }
    impl FakeResponder {
        fn calls(&self) -> Vec<RespondCall> {
            self.calls.lock().unwrap().clone()
        }
    }

    /// A gate that blocks in `gate()` until the test releases it — so the test can
    /// expire the request while the prompt is "up" (the F4 TOCTOU).
    struct BlockableGate {
        entered: Arc<Notify>,
        release: tokio::sync::Mutex<Option<oneshot::Receiver<AuthOutcome>>>,
    }
    impl BlockableGate {
        fn make() -> (AuthGateRef, Arc<Notify>, oneshot::Sender<AuthOutcome>) {
            let entered = Arc::new(Notify::new());
            let (tx, rx) = oneshot::channel();
            let gate = Arc::new(BlockableGate {
                entered: entered.clone(),
                release: tokio::sync::Mutex::new(Some(rx)),
            });
            (gate, entered, tx)
        }
    }
    #[async_trait::async_trait]
    impl AuthGate for BlockableGate {
        async fn gate(&self, _prompt: AuthPrompt) -> AuthOutcome {
            self.entered.notify_one();
            let rx = self.release.lock().await.take().expect("gate called once");
            rx.await.unwrap_or(AuthOutcome::Cancelled)
        }
    }

    struct DenyGate;
    #[async_trait::async_trait]
    impl AuthGate for DenyGate {
        async fn gate(&self, _prompt: AuthPrompt) -> AuthOutcome {
            AuthOutcome::Denied
        }
    }

    // -- harness helpers -----------------------------------------------------

    fn temp_audit() -> AuditStore {
        AuditStore::new(std::env::temp_dir().join(format!("shed-coord-{}/audit.jsonl", new_id())))
    }

    fn iso(unix: i64) -> String {
        crate::timefmt::format_iso8601(unix)
    }

    fn req(id: &str, ns: &str, shed: &str, server: &str, expires_unix: i64) -> ApprovalRequest {
        ApprovalRequest {
            id: id.into(),
            ts: iso(1_000),
            server: server.into(),
            namespace: ns.into(),
            op: "sign".into(),
            shed: shed.into(),
            detail: "ed25519".into(),
            expires_at: iso(expires_unix),
        }
    }

    fn ssh_req(id: &str, shed: &str, expires_unix: i64) -> ApprovalRequest {
        req(id, namespace::SSH, shed, "", expires_unix)
    }

    fn default_rule(action: PolicyAction, gate: PolicyGate) -> PolicyRule {
        PolicyRule {
            scope: PolicyScope::Default,
            server: None,
            namespace: None,
            shed: None,
            action,
            gate,
        }
    }

    struct Harness {
        coord: Coordinator,
        events: mpsc::UnboundedSender<HostAgentEvent>,
        responder: Arc<FakeResponder>,
        clock: ClockHandle,
    }

    impl Harness {
        fn build(gate: AuthGateRef, at: i64) -> Harness {
            let (clock, clock_handle) = ClockHandle::new(at);
            let responder = Arc::new(FakeResponder::default());
            let (events, event_rx) = mpsc::unbounded_channel();
            let deps = CoordinatorDeps {
                responder: responder.clone(),
                notifier: Arc::new(FakeNotifier::new()),
                gate,
                clock,
                audit: temp_audit(),
                ssh: SshPrefs::default(),
                extra_rules: vec![],
                provider_modes: HashMap::new(),
            };
            let coord = Coordinator::spawn(deps, event_rx);
            Harness {
                coord,
                events,
                responder,
                clock: clock_handle,
            }
        }

        fn new(at: i64) -> Harness {
            Harness::build(Arc::new(AlwaysApprovedGate), at)
        }

        fn inject(&self, req: ApprovalRequest) {
            self.events
                .send(HostAgentEvent::Frame(Box::new(
                    HostAgentInbound::ApprovalRequest(req),
                )))
                .unwrap();
        }

        async fn wait_queued(&self, n: usize) -> bool {
            for _ in 0..300 {
                if self.coord.approvals_list().await.len() == n {
                    return true;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            false
        }

        async fn wait_calls(&self, n: usize) -> bool {
            for _ in 0..300 {
                if self.responder.calls().len() >= n {
                    return true;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            false
        }
    }

    fn approve_session(ttl: &str) -> ApprovalChoice {
        ApprovalChoice {
            decision: ApprovalDecision::Approve,
            scope: Some(ApprovalScope::PerSession),
            ttl: Some(ttl.into()),
            persist: false,
        }
    }
    fn approve_sticky() -> ApprovalChoice {
        ApprovalChoice {
            decision: ApprovalDecision::Approve,
            scope: Some(ApprovalScope::PerShed),
            ttl: None,
            persist: false,
        }
    }
    fn deny() -> ApprovalChoice {
        ApprovalChoice {
            decision: ApprovalDecision::Deny,
            scope: None,
            ttl: None,
            persist: false,
        }
    }

    // -- tests ---------------------------------------------------------------

    #[tokio::test]
    async fn auto_approve_by_policy_never_queues() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Approve, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 1_030));
        assert!(h.wait_calls(1).await);
        let c = &h.responder.calls()[0];
        assert_eq!(c.decision, ApprovalDecision::Approve);
        assert_eq!(c.decided_by, DecidedBy::Policy);
        assert!(h.coord.approvals_list().await.is_empty());
    }

    #[tokio::test]
    async fn auto_deny_by_policy() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Deny, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 1_030));
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].decision, ApprovalDecision::Deny);
        assert_eq!(h.responder.calls()[0].decided_by, DecidedBy::Policy);
    }

    #[tokio::test]
    async fn prompt_then_manual_approve() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 1_030));
        assert!(h.wait_queued(1).await);
        h.coord
            .decide_approval(
                "r1",
                ApprovalChoice {
                    decision: ApprovalDecision::Approve,
                    scope: None,
                    ttl: None,
                    persist: false,
                },
            )
            .await;
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].decision, ApprovalDecision::Approve);
        assert_eq!(h.responder.calls()[0].decided_by, DecidedBy::User);
        assert!(h.coord.approvals_list().await.is_empty());
    }

    #[tokio::test]
    async fn expire_to_deny_after_ttl() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 1_005));
        assert!(h.wait_queued(1).await);
        h.clock.set(1_006); // past expiry
        h.coord.expire_now().await;
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].decision, ApprovalDecision::Deny);
        assert_eq!(h.responder.calls()[0].decided_by, DecidedBy::Timeout);
        assert!(h.coord.approvals_list().await.is_empty());
    }

    #[tokio::test]
    async fn per_session_grant_auto_approves_then_expires() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 2_000));
        assert!(h.wait_queued(1).await);
        h.coord.decide_approval("r1", approve_session("1h")).await;
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].scope.as_deref(), Some("per-session"));
        assert_eq!(h.responder.calls()[0].ttl.as_deref(), Some("1h"));
        // r2 same shed auto-approves via the grant.
        h.inject(ssh_req("r2", "s", 2_000));
        assert!(h.wait_calls(2).await);
        assert_eq!(h.responder.calls()[1].decided_by, DecidedBy::Policy);
        assert!(h.coord.approvals_list().await.is_empty());
        // advance past the 1h grant -> r3 re-prompts.
        h.clock.set(1_000 + 3_600 + 1);
        h.inject(ssh_req("r3", "s", 10_000));
        assert!(h.wait_queued(1).await);
    }

    #[tokio::test]
    async fn per_shed_sticky_grant() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "sticky", 5_000));
        assert!(h.wait_queued(1).await);
        h.coord.decide_approval("r1", approve_sticky()).await;
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].scope.as_deref(), Some("per-shed"));
        assert!(h.responder.calls()[0].ttl.is_none());
        // r2 same shed auto-approves; a different shed still prompts.
        h.inject(ssh_req("r2", "sticky", 5_000));
        assert!(h.wait_calls(2).await);
        h.inject(ssh_req("r3", "other", 5_000));
        assert!(h.wait_queued(1).await);
    }

    #[tokio::test]
    async fn deny_evicts_live_session_grant() {
        // F7: a deny supersedes a live "approve for this session" grant. Emit r1
        // AND r2 (same shed) BEFORE approving either, so both queue (no grant yet);
        // approve r1 (creates the grant), deny r2 (evicts it), then a fresh r3 on
        // that shed must RE-PROMPT rather than auto-approve.
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 5_000));
        h.inject(ssh_req("r2", "s", 5_000));
        assert!(h.wait_queued(2).await);
        h.coord.decide_approval("r1", approve_session("1h")).await;
        assert!(h.wait_calls(1).await);
        h.coord.decide_approval("r2", deny()).await;
        assert!(h.wait_calls(2).await);
        assert_eq!(h.responder.calls()[1].decision, ApprovalDecision::Deny);
        // The grant was evicted -> r3 on shed "s" re-prompts.
        h.inject(ssh_req("r3", "s", 5_000));
        assert!(h.wait_queued(1).await);
    }

    #[tokio::test]
    async fn reevaluate_pending_on_policy_change() {
        // Default prompt (AlwaysAsk) -> the ssh request queues; flip ssh policy to
        // always-deny -> the queued request auto-resolves to deny.
        let h = Harness::new(1_000);
        h.inject(ssh_req("r1", "s", 5_000));
        assert!(h.wait_queued(1).await);
        h.coord
            .set_ssh_approval(None, Some(SshApprovalPolicy::AlwaysDeny), None)
            .await;
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].decision, ApprovalDecision::Deny);
        assert_eq!(h.responder.calls()[0].decided_by, DecidedBy::Policy);
        assert!(h.coord.approvals_list().await.is_empty());
    }

    #[tokio::test]
    async fn disconnect_drops_all_pending() {
        // F3: a disconnect empties the queue; a late decide is a no-op.
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 5_000));
        assert!(h.wait_queued(1).await);
        h.events.send(HostAgentEvent::Disconnected).unwrap();
        assert!(h.wait_queued(0).await);
        // A late decide sends nothing (the request is gone).
        h.coord
            .decide_approval(
                "r1",
                ApprovalChoice {
                    decision: ApprovalDecision::Approve,
                    scope: None,
                    ttl: None,
                    persist: false,
                },
            )
            .await;
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(h.responder.calls().is_empty());
    }

    #[tokio::test]
    async fn persist_creates_per_shed_rule() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "keep", 5_000));
        assert!(h.wait_queued(1).await);
        h.coord
            .decide_approval(
                "r1",
                ApprovalChoice {
                    decision: ApprovalDecision::Approve,
                    scope: None,
                    ttl: None,
                    persist: true,
                },
            )
            .await;
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].scope.as_deref(), Some("always"));
        // policy_list now has a per-shed approve rule for "keep".
        let rules = h.coord.policy_list().await;
        assert!(rules.iter().any(|r| r.scope == PolicyScope::Shed
            && r.shed.as_deref() == Some("keep")
            && r.action == PolicyAction::Approve));
        // r2 on that shed auto-approves.
        h.inject(ssh_req("r2", "keep", 5_000));
        assert!(h.wait_calls(2).await);
    }

    #[tokio::test]
    async fn malformed_expires_at_cannot_be_approved() {
        // Fail-closed: an unparseable expires_at is treated as already-expired, so
        // a decide sends no approve.
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        let mut r = ssh_req("r1", "s", 5_000);
        r.expires_at = "garbage".into();
        h.inject(r);
        assert!(h.wait_queued(1).await);
        h.coord
            .decide_approval(
                "r1",
                ApprovalChoice {
                    decision: ApprovalDecision::Approve,
                    scope: None,
                    ttl: None,
                    persist: false,
                },
            )
            .await;
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(h.responder.calls().is_empty()); // no late approve
    }

    #[tokio::test]
    async fn gate_denied_keeps_request_pending() {
        // A biometric gate that denies leaves the request pending (mac-parity),
        // sends nothing.
        let h = Harness::build(Arc::new(DenyGate), 1_000);
        h.coord
            .set_policy_rules(vec![default_rule(
                PolicyAction::Prompt,
                PolicyGate::BiometricsOrPassword,
            )])
            .await;
        h.inject(ssh_req("r1", "s", 5_000));
        assert!(h.wait_queued(1).await);
        h.coord
            .decide_approval(
                "r1",
                ApprovalChoice {
                    decision: ApprovalDecision::Approve,
                    scope: None,
                    ttl: None,
                    persist: false,
                },
            )
            .await;
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(h.responder.calls().is_empty()); // gate denied -> nothing sent
        assert_eq!(h.coord.approvals_list().await.len(), 1); // still pending
    }

    #[tokio::test]
    async fn post_gate_toctou_no_late_approve() {
        // THE marquee test: hold the gate open, expire the request underneath it,
        // release Approved -> the wire decision is the tick's DENY, not a late
        // approve, and no grant is persisted.
        let (gate, entered, release) = BlockableGate::make();
        let h = Harness::build(gate, 1_000);
        h.coord
            .set_policy_rules(vec![default_rule(
                PolicyAction::Prompt,
                PolicyGate::BiometricsOrPassword,
            )])
            .await;
        h.inject(ssh_req("r1", "s", 1_030));
        assert!(h.wait_queued(1).await);
        // Start the approve — it reaches the gate and blocks.
        let c = h.coord.clone();
        let dec = tokio::spawn(async move { c.decide_approval("r1", approve_session("1h")).await });
        entered.notified().await; // gate is up
                                  // Expire the request while the prompt is up.
        h.clock.set(1_031);
        h.coord.expire_now().await; // tick denies r1
                                    // Now release the gate as Approved.
        release.send(AuthOutcome::Approved).unwrap();
        dec.await.unwrap();
        // Exactly one wire decision: the tick's DENY. No late approve.
        let calls = h.responder.calls();
        assert_eq!(calls.len(), 1, "expected only the tick's deny");
        assert_eq!(calls[0].decision, ApprovalDecision::Deny);
        assert_eq!(calls[0].decided_by, DecidedBy::Timeout);
        assert!(h.coord.approvals_list().await.is_empty());
        // And no grant was persisted (a follow-up request re-prompts).
        h.clock.set(1_000);
        h.inject(ssh_req("r2", "s", 5_000));
        assert!(h.wait_queued(1).await);
    }

    #[tokio::test]
    async fn notification_posted_and_invoked() {
        let h = Harness::new(1_000);
        h.coord
            .set_policy_rules(vec![default_rule(PolicyAction::Prompt, PolicyGate::None)])
            .await;
        h.inject(ssh_req("r1", "s", 5_000));
        assert!(h.wait_queued(1).await);
        assert_eq!(h.coord.notifications_list().await.len(), 1);
        assert!(
            h.coord
                .notification_invoke("r1", ApprovalDecision::Approve)
                .await
        );
        assert!(h.wait_calls(1).await);
        assert_eq!(h.responder.calls()[0].decision, ApprovalDecision::Approve);
        // withdrawn after resolution.
        assert!(h.coord.notifications_list().await.is_empty());
    }

    #[tokio::test]
    async fn event_stream_is_audited() {
        let h = Harness::new(1_000);
        let evt = shed_core::approval::AuditEventFrame {
            kind: Some("audit".into()),
            server: None,
            shed: Some("evt-shed".into()),
            ns: Some(namespace::AWS.into()),
            op: Some("get_credentials".into()),
            result: "ok".into(),
            detail: None,
            code: None,
            reason: None,
            approval: Some("none".into()),
            request_id: Some("e1".into()),
            ts: Some(iso(1_000)),
        };
        h.events
            .send(HostAgentEvent::Frame(Box::new(HostAgentInbound::Event(
                evt,
            ))))
            .unwrap();
        for _ in 0..300 {
            let a = h.coord.activity_list(10).await;
            if a.iter().any(|e| {
                e.ns.as_deref() == Some(namespace::AWS) && e.shed.as_deref() == Some("evt-shed")
            }) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("event was not audited");
    }

    #[tokio::test]
    async fn gate_namespaces_from_hello_ack() {
        let h = Harness::new(1_000);
        h.events
            .send(HostAgentEvent::Connected(shed_core::approval::HelloAck {
                namespaces: vec![],
                gate_namespaces: vec!["ssh-agent".into()],
                request_timeout_ms: 25_000,
                accepted: true,
            }))
            .unwrap();
        for _ in 0..300 {
            if h.coord.gate_namespaces().await == vec!["ssh-agent".to_string()] {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("gate_namespaces not published");
    }
}
