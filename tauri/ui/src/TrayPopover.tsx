/* TrayPopover — the macOS menu-bar popover (B1b), mirroring the Swift
   MenuBarContentView: a host-agent status dot, ≤3 pending-approval cards, ≤6
   running sheds, and a footer (Open dashboard · Preferences… · Check for Updates…
   [disabled] · Quit). A SEPARATE webview/entry from the dashboard shell, so it
   fetches its own data and reports its rows under the `popover` window key (never
   the dashboard's `main`, which `dashboard.dump`/`current_pane` read). */
import { useEffect, useState } from "react";
import { Fingerprint, Check, X, Shield } from "lucide-react";
import {
  inTauri, fetchSheds, fetchApprovals, fetchGateNamespaces, decideApproval,
  openDashboard, openPreferences, quitApp, reportTray,
  type Shed, type Approval,
} from "@/lib/bridge";

export default function TrayPopover() {
  const [sheds, setSheds] = useState<Shed[]>([]);
  const [approvals, setApprovals] = useState<Approval[]>([]);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    if (!inTauri()) return;
    let cancelled = false;
    // Per-slice generation guards (as in useUiBridge/useCoordinatorData) so a slower
    // older fetch can't overwrite a newer one's rows — events can outrun fetches.
    // `cancelled` drops any late resolve + unlistens if cleanup raced the async
    // listen() setup (StrictMode double-mount).
    const gen = { sheds: 0, approvals: 0, connected: 0 };
    const loadSheds = () => { const m = ++gen.sheds; void fetchSheds().then((v) => { if (!cancelled && m === gen.sheds) setSheds(v); }); };
    const loadApprovals = () => { const m = ++gen.approvals; void fetchApprovals().then((v) => { if (!cancelled && m === gen.approvals) setApprovals(v); }); };
    const loadConnected = () => { const m = ++gen.connected; void fetchGateNamespaces().then((ns) => { if (!cancelled && m === gen.connected) setConnected(ns.length > 0); }); };
    const loadAll = () => { loadSheds(); loadApprovals(); loadConnected(); };

    loadAll();
    const un: Array<() => void> = [];
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      // Live while shown: approvals + the host-agent dot re-fetch on coordinator
      // events; sheds on a lifecycle `refresh`; everything on the Rust show path's
      // `popover-refresh` so the popover freshens each time it opens.
      un.push(await listen("approvals-changed", loadApprovals));
      un.push(await listen("connected-changed", loadConnected));
      un.push(await listen("refresh", loadSheds));
      un.push(await listen("popover-refresh", loadAll));
      if (cancelled) un.forEach((u) => u()); // cleanup already ran before listen resolved
    })();
    return () => { cancelled = true; un.forEach((u) => u()); };
  }, []);

  const running = sheds.filter((s) => s.status === "running");
  const runningTop = running.slice(0, 6);
  const approvalsTop = approvals.slice(0, 3);

  // Report the rendered rows so `tray.dump` can assert the popover content (the
  // drivable truth, since OS tray clicks + a real screenshot aren't hermetic).
  useEffect(() => {
    if (!inTauri()) return;
    reportTray({
      connected,
      running_sheds: runningTop.map((s) => ({ host: s.host, name: s.name })),
      pending_approvals: approvalsTop.map((a) => ({ namespace: a.namespace, op: a.op, shed: a.shed })),
    });
  }, [connected, sheds, approvals]); // eslint-disable-line react-hooks/exhaustive-deps

  const decide = (a: Approval, decision: "approve" | "deny") =>
    void decideApproval(a.id, decision, { scope: a.default_scope, ttl: a.default_ttl });

  return (
    <div className="flex min-h-screen w-full flex-col bg-shed-bg text-shed-text" data-tray-popover>
      {/* header — host-agent status dot */}
      <div className="flex items-center justify-between px-3.5 py-2.5">
        <span className="text-[13px] font-semibold">shed desktop</span>
        <span className="flex items-center gap-1.5 text-[11px]"
              style={{ color: connected ? "var(--shed-ok)" : "var(--shed-text-muted)" }}>
          <span className="h-2 w-2 rounded-full"
                style={{ background: connected ? "var(--shed-ok)" : "var(--shed-text-muted)" }} />
          host agent
        </span>
      </div>
      <div className="h-px bg-shed-border" />

      {/* pending approvals (≤3) */}
      {approvalsTop.length > 0 && (
        <>
          <div className="bg-shed-deny-bg px-3.5 py-2">
            <div className="mb-1.5 text-[11px] font-semibold text-shed-danger">
              {approvals.length} pending approval{approvals.length === 1 ? "" : "s"}
            </div>
            {approvalsTop.map((a) => (
              <div key={a.id} className="flex items-center gap-2 py-1">
                <Shield size={14} className="shrink-0 text-shed-text-muted" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[12px] font-medium">{a.namespace} {a.op}</div>
                  <div className="truncate text-[11px] text-shed-text-muted">
                    {a.server ? `${a.server}/${a.shed}` : a.shed}
                  </div>
                </div>
                <button onClick={() => decide(a, "approve")} title="Approve" className="hbtn shrink-0 text-shed-ok">
                  {a.gate === "none" ? <Check size={16} /> : <Fingerprint size={16} />}
                </button>
                <button onClick={() => decide(a, "deny")} title="Deny" className="hbtn shrink-0 text-shed-danger">
                  <X size={16} />
                </button>
              </div>
            ))}
          </div>
          <div className="h-px bg-shed-border" />
        </>
      )}

      {/* running sheds (≤6) */}
      <div className="px-3.5 py-2">
        <div className="mb-1 flex items-center justify-between">
          <span className="text-[13px] font-semibold">Sheds</span>
          <span className="text-[11px] text-shed-text-muted">{running.length} running</span>
        </div>
        {runningTop.length === 0 ? (
          <div className="py-1 text-[12px] text-shed-text-muted">no running sheds</div>
        ) : (
          runningTop.map((s) => (
            <div key={`${s.host}/${s.name}`} className="flex items-center gap-2 py-1 text-[12px]">
              <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: "var(--shed-ok)" }} />
              <span className="truncate">{s.host}/{s.name}</span>
            </div>
          ))
        )}
      </div>
      <div className="h-px bg-shed-border" />

      {/* footer */}
      <div className="flex flex-col p-1.5">
        <FooterRow label="Open dashboard" onClick={() => void openDashboard()} />
        <FooterRow label="Preferences…" onClick={() => void openPreferences()} />
        <FooterRow label="Check for Updates…" disabled title="Updates arrive with the Tauri updater" />
        <FooterRow label="Quit" onClick={() => void quitApp()} />
      </div>
    </div>
  );
}

function FooterRow(
  { label, onClick, disabled, title }:
  { label: string; onClick?: () => void; disabled?: boolean; title?: string },
) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className="hlink rounded-md px-2.5 py-1.5 text-left text-[13px] disabled:opacity-40 disabled:hover:bg-transparent"
    >
      {label}
    </button>
  );
}
