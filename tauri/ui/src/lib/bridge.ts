import { useEffect, useRef } from "react";

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

function report(pane: Pane) {
  void tauriApi().then(({ core }) =>
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
 *  listener is live and a `ui.navigate` won't be missed to an attach race. */
export function useUiBridge(pane: Pane, setPane: (p: Pane) => void) {
  const paneRef = useRef(pane);
  paneRef.current = pane;

  useEffect(() => {
    if (!inTauri()) return;
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    void (async () => {
      const { event } = await tauriApi();
      const un = await event.listen<{ pane: Pane }>("navigate", (e) => {
        if (e.payload?.pane) setPane(e.payload.pane);
      });
      if (cancelled) {
        un();
        return;
      }
      unlisten = un;
      report(paneRef.current); // listener is live → signal readiness
    })();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [setPane]);

  // Report subsequent pane changes (the listener effect does the initial report,
  // after attach — so skip the mount run here to keep `current_pane` a
  // listener-is-ready signal). No requestAnimationFrame: it's paused while the
  // window is backgrounded, which a harness-launched app usually is.
  const mounted = useRef(false);
  useEffect(() => {
    if (!inTauri()) return;
    if (!mounted.current) {
      mounted.current = true;
      return;
    }
    report(pane);
  }, [pane]);
}
