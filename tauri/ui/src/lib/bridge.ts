import { useEffect, useRef } from "react";

export type Pane = "sheds" | "approvals" | "agents" | "activity" | "system";

const PANES: readonly Pane[] = ["sheds", "approvals", "agents", "activity", "system"];

/** Narrow an untrusted value (an IPC payload) to a known pane. */
export function isPane(x: unknown): x is Pane {
  return typeof x === "string" && (PANES as readonly string[]).includes(x);
}

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

function report(pane: Pane) {
  void import("@tauri-apps/api/core").then((core) =>
    core.invoke("ui_report", { pane, style: sampleStyle() }).catch(() => {}),
  );
}

/** Wire the shell to the Rust IPC drivability ops: listen for `navigate` (the
 *  `ui.navigate` op) and report the rendered pane + a computed-style sample back to
 *  Rust (`ui_report`), so `ui.current_pane` / `ui.computed_style` read the real
 *  rendered state. A no-op in a plain browser.
 *
 *  The initial report is emitted only AFTER the navigate listener is registered
 *  (its registration is async), so `current_pane != null` tells the harness the
 *  listener is live and a `ui.navigate` won't be lost to an attach race — which is
 *  also why `ui.navigate` fails `frontend_not_ready` until then. */
export function useUiBridge(pane: Pane, setPane: (p: Pane) => void) {
  const paneRef = useRef(pane);
  paneRef.current = pane;
  const ready = useRef(false);

  useEffect(() => {
    if (!inTauri()) return;
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      const un = await listen<{ pane?: unknown }>("navigate", (e) => {
        if (isPane(e.payload?.pane)) setPane(e.payload.pane);
      });
      if (cancelled) {
        un();
        return;
      }
      unlisten = un;
      ready.current = true; // listener live → readiness signal + initial style
      report(paneRef.current);
    })();
    return () => {
      cancelled = true;
      ready.current = false;
      unlisten?.();
    };
  }, [setPane]);

  // Report subsequent pane changes. Gated on `ready` (not a first-run flag) so it
  // stays reliable under React StrictMode's effect replay: the listener effect owns
  // the initial report, so `current_pane` remains a true "listener is live" signal.
  useEffect(() => {
    if (!inTauri() || !ready.current) return;
    report(pane);
  }, [pane]);
}
