// CSS audit for the Tauri frontend — a guard against WebKitGTK-hostile CSS
// creeping into the built bundle (e.g. via a shadcn/Tailwind/dependency bump).
//
// Two tiers:
//   - VERIFIED (oklch, color-mix): the linen theme uses these; WebKitGTK 2.44 (the
//     shipped target, Ubuntu 24.04) supports them — confirmed by the
//     tauri-build-linux render gate + the computed-style IPC probe. Reported only.
//   - RISKY (:has(), @container, @property, backdrop-filter): newer than the
//     verified baseline and not currently used. FAIL if introduced, so a dep bump
//     can't silently ship CSS the target can't render.
//
// Run: `npm run css-audit` (after `npm run build`).

import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath, URL } from "node:url";
import { join } from "node:path";

const DIST = fileURLToPath(new URL("../dist/assets/", import.meta.url));

const VERIFIED = [
  [/oklch\(/g, "oklch()"],
  [/color-mix\(/g, "color-mix()"],
];
const RISKY = [
  [/:has\(/g, ":has()"],
  [/@container[\s{(]/g, "@container"],
  [/@property\s/g, "@property"],
  [/backdrop-filter\s*:/g, "backdrop-filter"],
];

let css = "";
try {
  for (const f of readdirSync(DIST)) {
    if (f.endsWith(".css")) css += readFileSync(join(DIST, f), "utf8");
  }
} catch {
  console.error(`css-audit: no built CSS in ${DIST} — run \`npm run build\` first.`);
  process.exit(2);
}

const hits = (pats) =>
  pats.map(([re, name]) => [name, (css.match(re) || []).length]).filter(([, n]) => n > 0);

const verified = hits(VERIFIED);
const risky = hits(RISKY);

console.log("CSS audit (built bundle):");
if (verified.length) {
  console.log("  verified-on-target (WebKitGTK 2.44 OK):");
  for (const [name, n] of verified) console.log(`    ${name}: ${n}`);
}
if (risky.length) {
  console.error("  RISKY — newer than the verified baseline, not expected here:");
  for (const [name, n] of risky) console.error(`    ${name}: ${n}`);
  console.error(
    "\ncss-audit FAILED: the bundle uses CSS that may not render on the shipped\n" +
      "WebKitGTK. If a new component needs it, verify it on `make tauri-build-linux`\n" +
      "and move it to the VERIFIED tier, or avoid it.",
  );
  process.exit(1);
}
console.log("  no risky CSS features. OK.");
