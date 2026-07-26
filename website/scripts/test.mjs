import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import "./build.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const outputDirectory = path.resolve(scriptDirectory, "../dist");
const release = JSON.parse(await readFile(path.join(outputDirectory, "release.json"), "utf8"));
const chinese = await readFile(path.join(outputDirectory, "index.html"), "utf8");
const english = await readFile(path.join(outputDirectory, "en/index.html"), "utf8");
const styles = await readFile(path.join(outputDirectory, "styles.css"), "utf8");
const chineseText = chinese.replace(/<[^>]+>/g, "");

for (const [label, content] of [["Chinese page", chinese], ["English page", english]]) {
  if (content.includes("{{")) throw new Error(`${label} contains unresolved tokens`);
  if (!content.includes(`v${release.version}`)) throw new Error(`${label} has the wrong version`);
  if (!content.includes(release.file.sha256)) throw new Error(`${label} is missing SHA-256`);
  if (!content.includes(release.file.directDownloadURL)) {
    throw new Error(`${label} is missing the direct download URL`);
  }
  if (!content.includes(release.githubReleaseURL)) {
    throw new Error(`${label} is missing the GitHub release URL`);
  }
}

for (const copy of [
  "在 Mac 上自动隐藏或退出不需要的 App",
  "让精力更集中，让性能更集中。",
]) {
  if (!chineseText.includes(copy)) throw new Error(`Chinese hero is missing approved copy: ${copy}`);
}

if (!/h1\s*\{[^}]*letter-spacing:\s*-0\.03em\b/s.test(styles)) {
  throw new Error("Product name needs the approved letter spacing");
}

if (!/\.product-visual img\s*\{[^}]*\bheight:\s*auto\b/s.test(styles)) {
  throw new Error("Product screenshot must preserve its intrinsic aspect ratio");
}

for (const [pattern, message] of [
  [/\.button\s*\{[^}]*\bgap:\s*4px\b/s, "Download button text needs explicit spacing"],
  [/\.nowrap\s*\{[^}]*white-space:\s*nowrap\b/s, "Approved hero phrases must stay together"],
  [/\.soft \.eyebrow\s*\{[^}]*var\(--blue-on-soft\)/s, "Soft sections need an accessible accent color"],
  [
    /a:focus-visible,\s*button:focus-visible,\s*summary:focus-visible\s*\{[^}]*outline:\s*3px\s+solid[^}]*outline-offset:\s*3px/s,
    "Links, buttons, and disclosure controls need a visible focus ring",
  ],
]) {
  if (!pattern.test(styles)) throw new Error(message);
}

for (const [foreground, background] of [
  ["subtle", "surface"],
  ["blue-on-soft", "soft"],
]) {
  const ratio = contrastRatio(cssColor(foreground), cssColor(background));
  if (ratio < 4.5) {
    throw new Error(`${foreground} on ${background} has insufficient contrast: ${ratio.toFixed(2)}:1`);
  }
}

console.log(`PASS: bilingual product site metadata for v${release.version}`);

function cssColor(name) {
  const match = styles.match(new RegExp(`--${name}:\\s*(#[0-9a-f]{6})`, "i"));
  if (!match) throw new Error(`Missing CSS color variable: ${name}`);
  return match[1];
}

function contrastRatio(foreground, background) {
  const values = [foreground, background].map((color) => {
    const channels = [1, 3, 5].map((offset) => Number.parseInt(color.slice(offset, offset + 2), 16) / 255);
    return channels
      .map((channel) => channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4)
      .reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
  });
  return (Math.max(...values) + 0.05) / (Math.min(...values) + 0.05);
}
