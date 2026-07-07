import React from "react";
import ReactDOM from "react-dom/client";
import TrayPopover from "./TrayPopover";
import "./index.css";

// The macOS menu-bar popover — a SEPARATE React root from the dashboard shell, so
// it never mounts `useUiBridge` (which reports `pane`/`sheds` and would clobber the
// `main` snapshot). It reports its own compact rows under the `popover` window key.
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <TrayPopover />
  </React.StrictMode>,
);
