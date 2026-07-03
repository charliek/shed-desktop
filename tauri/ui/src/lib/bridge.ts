import { useCallback, useEffect, useRef, useState } from "react";

export type Pane = "sheds" | "approvals" | "agents" | "activity" | "system";

const PANES: readonly Pane[] = ["sheds", "approvals", "agents", "activity", "system"];

/** Narrow an untrusted value (an IPC payload) to a known pane. */
export function isPane(x: unknown): x is Pane {
  return typeof x === "string" && (PANES as readonly string[]).includes(x);
}

/** A shed as shed-core serializes it — the fields the dashboard reads (more exist). */
export type Shed = {
  name: string;
  host: string;
  status: string;
  backend?: string | null;
  image?: string | null;
  cpus?: number | null;
  memory_mb?: number | null;
};

/** Running inside a Tauri webview (vs a plain browser during `vite dev`)? */
function inTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Sample the rendered theme so the harness's computed-style probe can confirm
 *  the WebView actually applied the linen CSS (a resolved color, not a fallback). */
function sampleStyle() {
  const cs = getComputedStyle(document.body);
  const main = document.querySelector("[data-pane]");
  return {
    bg: cs.backgroundColor,
    color: cs.color,
    accent: main ? getComputedStyle(main).getPropertyValue("--shed-accent").trim() : "",
  };
}

/** Invoke a Rust command, swallowing errors to `undefined` (the shell degrades to
 *  an empty list rather than throwing inside an effect). */
async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | undefined> {
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args).catch(() => undefined);
}

/** Report the rendered snapshot Rust relays to the harness (`ui.current_pane` /
 *  `ui.computed_style` / `dashboard.dump`). One blob, so a new reader is one more
 *  key. The refresh token is echoed so `sheds.refresh` can block on it. */
function report(pane: Pane, sheds: Shed[], refreshToken: number, prefsOpen: boolean) {
  void invoke("ui_report", {
    snapshot: { pane, style: sampleStyle(), sheds, refresh_token: refreshToken, prefs_open: prefsOpen },
  });
}

/** Wire the shell to Rust: drive the pane from the `navigate` event, keep a live
 *  shed list (fetched on mount + on each `refresh` event — the `sheds.refresh`
 *  op), and report the rendered snapshot back so the harness can assert it.
 *  Returns the live sheds + a `refresh` callback (a lifecycle button chains it to
 *  re-fetch after its action). A no-op in a plain browser.
 *
 *  Readiness: the initial report is emitted only AFTER both the navigate + refresh
 *  listeners register, so `current_pane != null` tells the harness the listeners
 *  are live and a `ui.navigate`/`refresh` won't be lost to an attach race (which
 *  is also why `ui.navigate` fails `frontend_not_ready`, and `sheds.refresh` only
 *  blocks on the echo, until then). */
export function useUiBridge(
  pane: Pane,
  setPane: (p: Pane) => void,
  prefsOpen: boolean,
): { sheds: Shed[]; refresh: () => void } {
  const [sheds, setSheds] = useState<Shed[]>([]);
  const [refreshToken, setRefreshToken] = useState(0);
  // paneRef lets the mount effect read the latest pane for its initial report
  // without taking `pane` as a dep (which would re-subscribe the listeners).
  const paneRef = useRef(pane);
  paneRef.current = pane;
  const ready = useRef(false);
  const fetchGen = useRef(0);

  // Fetch the live shed list and store it; on a refresh, also advance the echoed
  // token so Rust's synchronous `sheds.refresh` observes completion. A generation
  // guard drops a superseded (slower, older) fetch so it can't overwrite a newer
  // one's rows OR re-report stale rows under an already-advanced token.
  const fetchSheds = useCallback(async (token: number) => {
    const gen = ++fetchGen.current;
    const rows = (await invoke<Shed[]>("list_sheds")) ?? [];
    if (gen !== fetchGen.current) return; // a newer fetch started — drop this one
    setSheds(rows);
    if (token > 0) setRefreshToken(token);
  }, []);

  useEffect(() => {
    if (!inTauri()) return;
    let cancelled = false;
    const unlisten: Array<() => void> = [];
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      unlisten.push(
        await listen<{ pane?: unknown }>("navigate", (e) => {
          if (isPane(e.payload?.pane)) setPane(e.payload.pane);
        }),
      );
      unlisten.push(
        await listen<{ token?: unknown }>("refresh", (e) => {
          const t = e.payload?.token;
          void fetchSheds(typeof t === "number" ? t : 0);
        }),
      );
      if (cancelled) {
        unlisten.forEach((u) => u());
        return;
      }
      ready.current = true; // both listeners live → readiness signal + initial report
      await fetchSheds(0);
      // Fresh sheds arrive via the report effect on the next render; this initial
      // report just publishes the pane, so `current_pane != null` = "listeners live".
      // The modal is always closed at mount.
      report(paneRef.current, [], 0, false);
    })();
    return () => {
      cancelled = true;
      ready.current = false;
      unlisten.forEach((u) => u());
    };
  }, [setPane, fetchSheds]);

  // Re-report on any rendered change (pane, sheds, or the echoed token). Gated on
  // `ready` (not a first-run flag) so the listener effect owns the initial report
  // and `current_pane` stays a true "listeners live" signal under StrictMode replay.
  useEffect(() => {
    if (!inTauri() || !ready.current) return;
    report(pane, sheds, refreshToken, prefsOpen);
  }, [pane, sheds, refreshToken, prefsOpen]);

  const refresh = useCallback(() => void fetchSheds(0), [fetchSheds]);
  return { sheds, refresh };
}

/** Fire a lifecycle action (a shed card button). The caller re-fetches via the
 *  hook's `refresh` so the card reflects the new state. Best-effort in a browser. */
export async function shedAction(action: string, name: string, host: string): Promise<void> {
  if (!inTauri()) return;
  await invoke("shed_action", { action, name, host });
}

/** Disk-usage shapes (shed-core's df models, serialized). */
export type DiskSize = { logical_bytes: number; physical_bytes: number };
export type DiskTotals = {
  images: DiskSize;
  sheds: DiskSize;
  snapshots: DiskSize;
  orphans: DiskSize;
  all: DiskSize;
};
export type HostDiskUsage = {
  host: string;
  usage: { backend?: string | null; totals: DiskTotals } | null;
  error?: string | null;
};

/** Per-host disk usage for the System pane (the same data the `system.df` op
 *  serves the harness). An unreachable host comes back as an error row. */
export async function fetchSystemDf(): Promise<HostDiskUsage[]> {
  return (await invoke<HostDiskUsage[]>("system_df")) ?? [];
}

/* ---- terminal + prefs (the Preferences view + the shed-card button) ------- */
export type TerminalPresetInfo = { id: string; label: string; detail: string; available: boolean };
export type TerminalPrefs = { terminal_preset: string; terminal_template: string };

export async function fetchTerminalPresets(): Promise<TerminalPresetInfo[]> {
  return (await invoke<{ presets: TerminalPresetInfo[] }>("terminal_presets"))?.presets ?? [];
}

export async function getPrefs(): Promise<TerminalPrefs> {
  return (
    (await invoke<TerminalPrefs>("get_prefs")) ?? { terminal_preset: "custom", terminal_template: "" }
  );
}

export async function setTerminalPref(preset: string, template?: string): Promise<void> {
  await invoke("set_terminal_pref", { preset, template });
}

/** Open a shed in the user's chosen terminal (best-effort; a no-op in a browser
 *  and disabled server-side under test mode). */
export async function openTerminal(shed: string, host: string): Promise<void> {
  if (!inTauri()) return;
  await invoke("open_terminal", { shed, host });
}
