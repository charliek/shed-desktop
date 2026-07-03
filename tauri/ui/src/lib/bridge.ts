import { useEffect } from "react";

export type Pane = "sheds" | "approvals" | "agents" | "activity" | "system";

/** Running inside a Tauri webview (vs a plain browser during `vite dev`)? */
function inTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

async function tauriApi() {
  const [core, event] = await Promise.all([
    import("@tauri-apps/api/core"),
    import("@tauri-apps/api/event"),
  ]);
  return { core, event };
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

/** Wire the shell to the Rust IPC drivability ops: listen for `navigate` (the
 *  `ui.navigate` op) and report the rendered pane + a computed-style sample back
 *  to Rust (`ui_report`), so `ui.current_pane` / `ui.computed_style` can read the
 *  real rendered state. A no-op in a plain browser. */
export function useUiBridge(pane: Pane, setPane: (p: Pane) => void) {
  useEffect(() => {
    if (!inTauri()) return;
    let unlisten: (() => void) | undefined;
    void tauriApi().then(({ event }) =>
      event
        .listen<{ pane: Pane }>("navigate", (e) => {
          if (e.payload?.pane) setPane(e.payload.pane);
        })
        .then((fn) => {
          unlisten = fn;
        }),
    );
    return () => unlisten?.();
  }, [setPane]);

  useEffect(() => {
    if (!inTauri()) return;
    // rAF so computed styles reflect the new pane before we sample.
    const id = requestAnimationFrame(() => {
      void tauriApi().then(({ core }) =>
        core.invoke("ui_report", { pane, style: sampleStyle() }).catch(() => {}),
      );
    });
    return () => cancelAnimationFrame(id);
  }, [pane]);
}
