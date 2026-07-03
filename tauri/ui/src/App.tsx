/* shed desktop — the app shell (A0b). Sidebar + header + the five panes,
   rendered from static seed data so the linen shell matches the mockup; A1b/A1c
   wire live shed-core data + the dialogs. Nav is driven by clicks AND by the Rust
   `ui.navigate` op (via the `navigate` Tauri event); the rendered pane + a
   computed-style sample are reported back to Rust (useUiBridge) so the harness can
   assert them over IPC. */
import { useEffect, useState } from "react";
import {
  Boxes, Shield, Sparkles, ScrollText, HardDrive, Box, TriangleAlert, Plus,
  Terminal, RotateCw, Square, Play, Trash2, RefreshCw, ExternalLink, Key,
  Fingerprint, Moon, Sun,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useUiBridge, type Pane } from "@/lib/bridge";

/* ---- seed data (static preview; A1b makes it live) ------------------------ */
const IMG = "shed-vz-full:v0.7.6";
const SEED_SHEDS = [
  { id: "s1", host: "localmac-dev", name: "sd-gtk-dev", backend: "vz", image: IMG, cpus: 2, mem: "4 GB", meta: "stopped", state: "stopped" },
  { id: "s2", host: "localmac-dev", name: "ztest", backend: "vz", image: IMG, cpus: 2, mem: "4 GB", meta: "2 vCPU · 4 GB · up 2d", state: "running" },
];
const SEED_AGENTS = [
  { id: "g1", shed: "localmac-dev/ztest", name: "claude-test", kind: "claude-rc", status: "ready", sub: "tmux rc-dqtzeu · /home/shed · made by shed" },
];
const SEED_ACTIVITY = [
  ["01:21:01", "sign · localmac-dev/ztest · ssh-ed25519", "shed-desktop"],
  ["01:21:01", "sign · localmac-dev/ztest · SSH sign request", "shed-desktop"],
  ["01:21:01", "list · localmac-dev/ztest · 1 keys", null],
  ["01:20:50", "sign · localmac-dev/ztest · ssh-ed25519", "shed-desktop"],
].map((r, i) => ({ id: "a" + i, time: r[0] as string, detail: r[1] as string, gate: r[2] as string | null }));
const SEED_APPROVALS = [
  { id: "ap1", op: "sign", target: "localmac-dev/ztest", desc: "SSH sign request", expires: 18 },
];
const TRANSPORT_ERR =
  'transport error: Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."';
const HOSTS = [
  { name: "localmac-dev", backend: "vz", online: true, total: "4.34 GB", parts: ["1.9 GB", "2.43 GB", "Zero KB", "Zero KB"] },
  { name: "mini2", backend: "firecracker", online: true, total: "1.36 GB", parts: ["1.36 GB", "Zero KB", "Zero KB", "Zero KB"] },
  { name: "mini3", backend: "firecracker", online: true, total: "1.36 GB", parts: ["1.36 GB", "Zero KB", "Zero KB", "Zero KB"] },
  { name: "mini3-dev", backend: null, online: false, error: TRANSPORT_ERR },
  { name: "my-server-dev", backend: null, online: false, error: TRANSPORT_ERR },
];

const NAV: [Pane, string, typeof Box][] = [
  ["sheds", "Sheds", Boxes],
  ["approvals", "Approvals", Shield],
  ["agents", "Agents", Sparkles],
  ["activity", "Activity", ScrollText],
  ["system", "System", HardDrive],
];

/* ---- small building blocks ------------------------------------------------ */
function Dot({ className, style }: { className?: string; style?: React.CSSProperties }) {
  return <span style={style} className={cn("inline-block h-[9px] w-[9px] rounded-full", className)} />;
}

function Tag({ kind }: { kind: string }) {
  const vz = kind === "vz";
  return (
    <span
      className="rounded-md px-2 py-1 text-[12px] font-semibold leading-none"
      style={{
        background: vz ? "var(--shed-tag-vz-bg)" : "var(--shed-tag-fc-bg)",
        color: vz ? "var(--shed-tag-vz-text)" : "var(--shed-tag-fc-text)",
      }}
    >
      {kind}
    </span>
  );
}

function ImageChip({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded-md bg-shed-inset px-2 py-1 font-mono text-[12px] font-medium leading-none text-shed-text-secondary">
      {children}
    </span>
  );
}

function PageHead({ title, sub, right }: { title: string; sub?: string; right?: React.ReactNode }) {
  return (
    <div className="mb-6 flex items-start gap-4">
      <div className="flex-1">
        <h1 className="text-[22px] font-bold leading-tight text-shed-text">{title}</h1>
        {sub && <p className="mt-1.5 text-[14px] text-shed-text-muted">{sub}</p>}
      </div>
      {right}
    </div>
  );
}

function HeadAction({ icon: Icon, label, onClick }: { icon: typeof Box; label: string; onClick?: () => void }) {
  return (
    <button
      onClick={onClick}
      className="hbtn inline-flex items-center gap-2 rounded-[10px] px-3.5 py-2.5 text-[15px] font-semibold text-shed-accent-fg"
      style={{ background: "var(--shed-accent)" }}
    >
      <Icon size={17} />
      {label}
    </button>
  );
}

function IconBtn({ icon: Icon, tone = "neutral", title, onClick, spin, disabled }:
  { icon: typeof Box; tone?: "neutral" | "accent" | "ok" | "attention" | "danger"; title?: string; onClick?: () => void; spin?: boolean; disabled?: boolean }) {
  const tinted = tone !== "neutral";
  const v = `var(--shed-${tone})`;
  return (
    <button
      onClick={onClick}
      title={title}
      disabled={disabled}
      className="hbtn inline-flex h-[34px] w-[42px] flex-none items-center justify-center rounded-lg"
      style={{
        border: `1px solid ${tinted ? `color-mix(in oklch, ${v} 26%, var(--shed-border))` : "var(--shed-border)"}`,
        background: tinted ? `color-mix(in oklch, ${v} 13%, var(--shed-inset))` : "var(--shed-inset)",
        color: tinted ? v : "var(--shed-text-secondary)",
        opacity: disabled ? 0.45 : 1,
      }}
    >
      <Icon size={17} className={spin ? "animate-spin" : undefined} />
    </button>
  );
}

const card = "rounded-shed border border-shed-border bg-shed-surface shadow-shed";

/* ---- panes ---------------------------------------------------------------- */
function ShedsPane() {
  const unreachable = HOSTS.filter((h) => !h.online).length;
  return (
    <div>
      <PageHead
        title="Sheds"
        right={
          <div className="flex items-center gap-4">
            {unreachable > 0 && (
              <span className="inline-flex items-center gap-1.5 text-[14px] font-semibold" style={{ color: "var(--shed-attention)" }}>
                <TriangleAlert size={17} /> {unreachable} hosts unreachable
              </span>
            )}
            <HeadAction icon={Plus} label="New shed" />
          </div>
        }
      />
      <div className="mb-2 pl-0.5 text-[12px] font-semibold uppercase tracking-wider text-shed-text-muted">localmac-dev</div>
      <div className="flex flex-col gap-3">
        {SEED_SHEDS.map((s) => {
          const running = s.state === "running";
          return (
            <div key={s.id} className={cn(card, "flex items-center gap-4 px-5 py-[18px]")} style={{ animation: "shed-in .25s ease" }}>
              <Dot style={{ background: running ? "var(--shed-ok)" : "var(--shed-text-muted)" }} className="h-[11px] w-[11px]" />
              <div className="min-w-0 flex-1">
                <div className="mb-1.5 flex flex-wrap items-center gap-2.5">
                  <span className="text-[19px] font-bold text-shed-text">{s.name}</span>
                  <Tag kind={s.backend} />
                  <ImageChip>{s.image}</ImageChip>
                </div>
                <div className="text-[14px] text-shed-text-muted">{s.meta}</div>
              </div>
              <div className="flex gap-2.5">
                {running ? (
                  <>
                    <IconBtn icon={Terminal} tone="accent" title="Open in Terminal" />
                    <IconBtn icon={RotateCw} tone="attention" title="Restart" />
                    <IconBtn icon={Square} tone="danger" title="Stop" />
                  </>
                ) : (
                  <>
                    <IconBtn icon={Play} tone="ok" title="Start" />
                    <IconBtn icon={Trash2} tone="danger" title="Delete" />
                  </>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ApprovalsPane() {
  return (
    <div>
      <PageHead
        title="Credential approvals"
        sub="Requests routed from shed-host-agent when its approval mode is shed-desktop."
        right={<span className="text-[14px] text-shed-text-muted">gate: shed-desktop</span>}
      />
      <div className="flex flex-col gap-3">
        {SEED_APPROVALS.map((a) => (
          <div key={a.id} className={cn(card, "p-5")} style={{ animation: "shed-in .25s ease" }}>
            <div className="flex items-start gap-4">
              <div className="flex h-11 w-11 flex-none items-center justify-center rounded-xl" style={{ background: "var(--shed-tag-vz-bg)" }}>
                <Key size={20} style={{ color: "var(--shed-tag-vz-text)" }} />
              </div>
              <div className="min-w-0 flex-1">
                <div className="text-[18px] font-bold text-shed-text">ssh-agent · {a.op}</div>
                <div className="mt-1.5 text-[14px] leading-snug text-shed-text-muted">shed {a.target} · {a.desc}</div>
              </div>
              <span className="flex-none text-[14px] font-semibold" style={{ color: "var(--shed-attention)" }}>expires in {a.expires}s</span>
            </div>
            <div className="mt-[18px] flex items-center">
              <span className="flex-1 text-[13px] text-shed-text-muted">Approve allows this request only</span>
              <div className="flex gap-2.5">
                <button className="hbtn rounded-[10px] px-5 py-[11px] text-[15px] font-semibold" style={{ background: "var(--shed-deny-bg)", color: "var(--shed-danger)" }}>Deny</button>
                <button className="hbtn inline-flex items-center gap-2 rounded-[10px] px-[22px] py-[11px] text-[15px] font-semibold" style={{ background: "var(--shed-approve)", color: "var(--shed-approve-fg)" }}>
                  <Fingerprint size={18} /> Approve (Touch ID)
                </button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function AgentsPane() {
  return (
    <div>
      <PageHead
        title="Remote-control agents"
        sub="Drive an agent — a REPL, a shell, or a coding agent — inside a shed from here."
        right={<HeadAction icon={Plus} label="New session" />}
      />
      <div className="flex flex-col gap-3">
        {SEED_AGENTS.map((g) => (
          <div key={g.id} className={cn(card, "flex items-center gap-3.5 py-3.5 pl-3.5 pr-4")} style={{ animation: "shed-in .25s ease" }}>
            <span className="inline-flex min-w-[74px] flex-none items-center justify-center rounded-[9px] px-3 py-2.5 text-[14px] font-semibold" style={{ background: "color-mix(in oklch, var(--shed-ok) 15%, var(--shed-inset))", color: "var(--shed-ok)" }}>{g.status}</span>
            <div className="min-w-0 flex-1">
              <div className="mb-1 flex flex-wrap items-center gap-2.5">
                <span className="text-[16px] font-bold text-shed-text">ztest/{g.name}</span>
                <span className="rounded-md bg-shed-inset px-2 py-1 font-mono text-[12px] font-medium text-shed-text-secondary">{g.kind}</span>
              </div>
              <div className="truncate text-[13px] text-shed-text-muted">{g.sub}</div>
            </div>
            <button className="hbtn inline-flex flex-none items-center gap-2 rounded-[9px] px-[15px] py-[9px] text-[14px] font-semibold" style={{ background: "color-mix(in oklch, var(--shed-accent) 13%, var(--shed-inset))", border: "1px solid color-mix(in oklch, var(--shed-accent) 26%, var(--shed-border))", color: "var(--shed-accent)" }}>
              <ExternalLink size={16} /> Open in Claude
            </button>
            <IconBtn icon={Terminal} tone="accent" title="Open in Terminal" />
            <IconBtn icon={Trash2} tone="danger" title="End session" />
          </div>
        ))}
      </div>
    </div>
  );
}

function ActivityPane() {
  return (
    <div>
      <PageHead
        title="Activity"
        sub="Host-agent credential audit + shed-desktop decisions, newest first."
        right={<HeadAction icon={ScrollText} label="Reveal log" />}
      />
      <div className={cn(card, "overflow-hidden")}>
        {SEED_ACTIVITY.map((r, i) => (
          <div key={r.id} className={cn("row-hover flex items-center gap-3.5 px-[18px] py-[13px]", i && "border-t border-shed-border")}>
            <span className="w-[70px] flex-none font-mono text-[13px] text-shed-text-muted">{r.time}</span>
            <span className="flex-none rounded-md px-1.5 py-1 font-mono text-[11px] font-semibold" style={{ background: "var(--shed-agent-pill-bg)", color: "var(--shed-agent-pill-text)" }}>ssh-agent</span>
            <span className="min-w-0 flex-1 truncate text-[14px] text-shed-text-secondary">{r.detail}</span>
            <span className="flex flex-none items-center gap-2">
              <span className="text-[13px] font-semibold" style={{ color: "var(--shed-ok)" }}>ok</span>
              {r.gate && <span className="text-[12px] text-shed-text-muted">{r.gate}</span>}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

function SystemPane() {
  return (
    <div>
      <PageHead title="System" sub="Disk usage per host (images, sheds, snapshots, orphans)." right={<HeadAction icon={RefreshCw} label="Refresh" />} />
      <div className="flex flex-col gap-3.5">
        {HOSTS.map((h) => (
          <div key={h.name} className={cn(card, "px-5 py-4")}>
            <div className={cn("flex items-center gap-3", h.online ? "mb-4" : "mb-3")}>
              <HardDrive size={20} className="text-shed-text-muted" />
              <span className="text-[17px] font-bold text-shed-text">{h.name}</span>
              {h.backend && <Tag kind={h.backend} />}
              <span className="flex-1" />
              {h.online && <span className="text-[19px] font-bold text-shed-text">{h.total}</span>}
            </div>
            {h.online ? (
              <div className="grid grid-cols-4 gap-2.5">
                {["Images", "Sheds", "Snapshots", "Orphans"].map((label, j) => (
                  <div key={label}>
                    <div className="mb-1.5 text-[12px] text-shed-text-muted">{label}</div>
                    <div className="font-mono text-[15px] font-medium text-shed-text">{h.parts![j]}</div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="break-words font-mono text-[13px] leading-relaxed" style={{ color: "var(--shed-danger)" }}>{h.error}</div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

const PANES: Record<Pane, () => JSX.Element> = {
  sheds: ShedsPane,
  approvals: ApprovalsPane,
  agents: AgentsPane,
  activity: ActivityPane,
  system: SystemPane,
};

/* ---- shell ---------------------------------------------------------------- */
export default function App() {
  const [pane, setPane] = useState<Pane>("sheds");
  const [mode, setMode] = useState<"light" | "dark">("light");
  useUiBridge(pane, setPane);

  useEffect(() => {
    document.documentElement.dataset.mode = mode;
  }, [mode]);

  const pending = SEED_APPROVALS.length;
  const Body = PANES[pane];

  return (
    <div className="flex h-full">
      {/* sidebar */}
      <aside className="flex w-[232px] flex-none flex-col gap-1 border-r border-shed-border bg-shed-bg-sidebar px-3 py-3.5">
        {NAV.map(([id, label, Icon]) => {
          const active = pane === id;
          const badge = id === "sheds" ? SEED_SHEDS.length : id === "approvals" && pending ? pending : null;
          const alert = id === "approvals" && pending > 0;
          return (
            <button
              key={id}
              onClick={() => setPane(id)}
              className={cn("nav-item flex w-full items-center gap-3 rounded-[9px] px-[11px] py-[9px] text-left text-[15px] font-semibold", active && "is-active")}
              style={{
                background: active ? "var(--shed-accent-subtle)" : "transparent",
                boxShadow: active ? "inset 0 0 0 1px var(--shed-accent-border)" : undefined,
              }}
            >
              <Icon size={18} style={{ color: active ? "var(--shed-accent)" : "var(--shed-text-muted)" }} />
              <span className="flex-1" style={{ color: active ? "var(--shed-text)" : "var(--shed-text-secondary)" }}>{label}</span>
              {badge != null && (
                <span
                  className="inline-flex h-5 min-w-[20px] items-center justify-center rounded-[7px] px-1.5 font-mono text-[12px] font-semibold"
                  style={{ background: alert ? "var(--shed-deny-bg)" : "var(--shed-inset)", color: alert ? "var(--shed-danger)" : "var(--shed-text-muted)" }}
                >
                  {badge}
                </span>
              )}
            </button>
          );
        })}
        <div className="mx-[11px] my-3 h-px bg-shed-border" />
        <div className="px-[11px] pb-2 pt-0.5 text-[11px] font-semibold tracking-wider text-shed-text-muted">HOSTS</div>
        {HOSTS.map((h) => (
          <div key={h.name} className="flex items-center gap-3 px-[11px] py-[7px] text-[14px] font-medium" style={{ color: h.online ? "var(--shed-text-secondary)" : "var(--shed-text-muted)" }}>
            <Dot style={{ background: h.online ? "var(--shed-ok)" : "var(--shed-text-muted)" }} />
            <span>{h.name}</span>
          </div>
        ))}
        <div className="flex-1" />
      </aside>

      {/* main column */}
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-[52px] flex-none items-center gap-3 border-b border-shed-border bg-shed-bg px-[22px]">
          <Box size={20} className="text-shed-text-secondary" />
          <span className="text-[15px] font-semibold text-shed-text">shed desktop</span>
          <div className="flex-1" />
          {pending > 0 && (
            <button onClick={() => setPane("approvals")} className="hlink inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-[13px] font-semibold" style={{ color: "var(--shed-danger)" }}>
              <Shield size={15} /> {pending} pending
            </button>
          )}
          <span className="inline-flex items-center gap-2 text-[13px] font-medium text-shed-text-secondary">
            <Dot className="h-2 w-2" style={{ background: "var(--shed-ok)" }} /> host agent · connected
          </span>
          <button onClick={() => setMode(mode === "light" ? "dark" : "light")} title="Toggle appearance" className="hlink ml-1 flex h-7 w-7 items-center justify-center rounded-md text-shed-text-muted">
            {mode === "light" ? <Moon size={15} /> : <Sun size={15} />}
          </button>
        </header>
        <main className="flex-1 overflow-auto bg-shed-bg px-[38px] py-7">
          <div className="mx-auto max-w-[880px]" data-pane={pane}>
            <Body />
          </div>
        </main>
      </div>
    </div>
  );
}
