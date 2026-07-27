import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { escapeHTML } from "../lib/release-history-core.mjs";
import "./build.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const outputDirectory = path.resolve(scriptDirectory, "../dist");
const release = JSON.parse(await readFile(path.join(outputDirectory, "release.json"), "utf8"));
const releaseHistory = JSON.parse(
  await readFile(path.join(outputDirectory, "release-history.json"), "utf8"),
);
const chinese = await readFile(path.join(outputDirectory, "index.html"), "utf8");
const english = await readFile(path.join(outputDirectory, "en/index.html"), "utf8");
const chineseChangelog = await readFile(
  path.join(outputDirectory, "changelog/index.html"),
  "utf8",
);
const englishChangelog = await readFile(
  path.join(outputDirectory, "en/changelog/index.html"),
  "utf8",
);
const sitemap = await readFile(path.join(outputDirectory, "sitemap.xml"), "utf8");
const styles = await readFile(path.join(outputDirectory, "styles.css"), "utf8");
const edgeOne = JSON.parse(await readFile(path.resolve(outputDirectory, "../edgeone.json"), "utf8"));
const chineseText = chinese.replace(/<[^>]+>/g, "");

const darkSchemeMedia = styles.match(
  /@media[^\{]*\(\s*prefers-color-scheme\s*:\s*dark\s*\)[^\{]*\{/i,
);
if (!darkSchemeMedia) {
  throw new Error("Product site needs a prefers-color-scheme: dark media block");
}

const rootBlocks = [...styles.matchAll(/:root\s*\{([^}]*)\}/gi)];
if (rootBlocks.length < 2) {
  throw new Error("Product site needs separate light and dark :root theme token sets");
}
if (rootBlocks[1].index < darkSchemeMedia.index) {
  throw new Error("The second :root theme token set must belong to the dark color-scheme override");
}
const themes = {
  light: cssTheme(rootBlocks[0][1], "light"),
  dark: cssTheme(rootBlocks[1][1], "dark"),
};

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
  verifyThemeMetadata(label, content);
  verifyDirectDownloadLinks(label, content, release.file.directDownloadURL);
  verifyHeroDownloadMetadataLayout(label, content);
}

for (const [label, content, language] of [
  ["Chinese changelog", chineseChangelog, "zh-CN"],
  ["English changelog", englishChangelog, "en"],
]) {
  if (content.includes("{{")) throw new Error(`${label} contains unresolved tokens`);
  let previousIndex = -1;
  for (const entry of [...releaseHistory.releases].reverse()) {
    const versionIndex = content.indexOf(`QuitHide v${entry.version}`);
    if (versionIndex <= previousIndex) {
      throw new Error(`${label} must list every version newest first`);
    }
    previousIndex = versionIndex;
    if (!content.includes(escapeHTML(entry.releaseNotes[language]))) {
      throw new Error(`${label} is missing release notes for v${entry.version}`);
    }
    if (
      !content.includes(
        `https://github.com/jiangsir-tech/QuitHide/releases/tag/v${entry.version}`,
      )
    ) {
      throw new Error(`${label} is missing the GitHub release for v${entry.version}`);
    }
  }
  verifyThemeMetadata(label, content);
}

if (!chinese.includes('href="/changelog/"')) {
  throw new Error("Chinese product page must link to the changelog");
}
if (!english.includes('href="/en/changelog/"')) {
  throw new Error("English product page must link to the changelog");
}
for (const route of ["/changelog/", "/en/changelog/"]) {
  if (!sitemap.includes(`<loc>http://localhost:4173${route}</loc>`)) {
    throw new Error(`Sitemap is missing ${route}`);
  }
}

verifyDownloadCountMarkup(
  "Chinese page",
  chinese,
  "累计下载 24 次 · 每日更新",
);
verifyDownloadCountMarkup(
  "English page",
  english,
  "24 cumulative downloads · Updated daily",
);

const directDownloadURL = new URL(release.file.directDownloadURL);
if (directDownloadURL.origin !== "https://quithide-downloads-1313533016.cos.ap-hongkong.myqcloud.com") {
  throw new Error("Direct product downloads must remain on the verified Hong Kong COS origin");
}

const downloadStatsSchedule = edgeOne.schedules?.filter(({ path: route }) => (
  route === "/api/cron/aggregate-downloads"
));
if (downloadStatsSchedule?.length !== 1) {
  throw new Error("EdgeOne needs exactly one scheduled download-stat aggregation job");
}
if (
  downloadStatsSchedule[0].cron !== "17 0 * * *" ||
  downloadStatsSchedule[0].method !== "POST" ||
  downloadStatsSchedule[0].timezone !== "UTC"
) {
  throw new Error("Download statistics must refresh daily through the approved EdgeOne schedule");
}

for (const copy of [
  "按设定规则自动退出或隐藏 Mac 上打开的 App",
  "节省人的精力，节省 Mac 的性能。",
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

for (const [themeName, colors] of Object.entries(themes)) {
  for (const [foreground, background] of [
    ["text", "page"],
    ["muted", "page"],
    ["subtle", "surface"],
    ["blue-on-soft", "soft"],
    ["check-text", "soft"],
    ["green", "badge-background"],
    ["on-accent", "blue"],
  ]) {
    const ratio = contrastRatio(
      themeColor(colors, foreground, themeName),
      themeColor(colors, background, themeName),
    );
    if (ratio < 4.5) {
      throw new Error(
        `${themeName} theme ${foreground} on ${background} has insufficient contrast: ${ratio.toFixed(2)}:1`,
      );
    }
  }
}

const appcastHeaders = edgeOne.headers?.find((rule) => rule.source === "/appcast.xml")?.headers;
if (!appcastHeaders?.some(({ key, value }) => (
  key.toLowerCase() === "cache-control" && value.includes("must-revalidate")
))) {
  throw new Error("Sparkle appcast needs a short revalidating EdgeOne cache policy");
}
if (!appcastHeaders?.some(({ key, value }) => (
  key.toLowerCase() === "content-type" && value.startsWith("application/xml")
))) {
  throw new Error("Sparkle appcast needs an XML content type");
}

console.log(`PASS: bilingual product site metadata for v${release.version}`);

function cssColor(name) {
  const match = styles.match(new RegExp(`--${name}:\\s*(#[0-9a-f]{6})`, "i"));
  if (!match) throw new Error(`Missing CSS color variable: ${name}`);
  return match[1];
}

function cssTheme(block, name) {
  const colors = {};
  for (const match of block.matchAll(/--([a-z0-9-]+):\s*(#[0-9a-f]{6})\s*;/gi)) {
    colors[match[1].toLowerCase()] = match[2].toLowerCase();
  }
  if (Object.keys(colors).length === 0) {
    throw new Error(`The ${name} :root theme token set has no hexadecimal colors`);
  }
  return colors;
}

function themeColor(theme, token, themeName) {
  const color = theme[token];
  if (!color) throw new Error(`Missing ${themeName} theme color variable: ${token}`);
  return color;
}

function verifyThemeMetadata(label, content) {
  const metadata = [...content.matchAll(/<meta\b[^>]*>/gi)].map(([tag]) => {
    const attributes = {};
    for (const match of tag.matchAll(/([a-z][a-z0-9:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/gi)) {
      attributes[match[1].toLowerCase()] = match[2] ?? match[3];
    }
    return attributes;
  });

  const colorScheme = metadata.find(({ name }) => name?.toLowerCase() === "color-scheme");
  if (colorScheme?.content?.trim().toLowerCase().replace(/\s+/g, " ") !== "light dark") {
    throw new Error(`${label} must declare color-scheme light dark`);
  }

  const themeColors = metadata.filter(({ name }) => name?.toLowerCase() === "theme-color");
  for (const scheme of ["light", "dark"]) {
    const expectedMedia = `(prefers-color-scheme:${scheme})`;
    const match = themeColors.find(({ media }) => (
      media?.toLowerCase().replace(/\s+/g, "") === expectedMedia
    ));
    if (!match || !/^#[0-9a-f]{6}$/i.test(match.content ?? "")) {
      throw new Error(`${label} needs a hexadecimal ${scheme} theme-color with matching media`);
    }
  }
}

function verifyDirectDownloadLinks(label, content, expectedURL) {
  const links = [...content.matchAll(/<a\b[^>]*\bdata-direct-download\b[^>]*>/gi)];
  if (links.length !== 3) {
    throw new Error(`${label} must expose exactly three direct-download links`);
  }
  for (const [tag] of links) {
    const href = tag.match(/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')/i)?.slice(1).find(Boolean);
    if (href !== expectedURL) {
      throw new Error(`${label} direct-download links must keep the verified COS URL`);
    }
  }
  for (const [attribute, endpoint] of [
    ["data-download-event", "/api/download-events"],
    ["data-download-stats", "/api/download-stats"],
  ]) {
    if (!content.includes(`${attribute}="${endpoint}"`)) {
      throw new Error(`${label} is missing ${attribute}=${endpoint}`);
    }
  }
}

function verifyDownloadCountMarkup(label, content, expectedCopy) {
  const counters = [...content.matchAll(
    /<([a-z][a-z0-9]*)\b([^>]*)\bdata-download-count\s*=\s*(?:"([^"]*)"|'([^']*)')([^>]*)>([^<]*)<\/\1>/gi,
  )];
  if (counters.length !== 1) {
    throw new Error(`${label} must contain exactly one visible download counter`);
  }
  const initialValue = counters[0][3] ?? counters[0][4];
  if (initialValue !== "24" || counters[0][6].trim() !== "24") {
    throw new Error(`${label} download counter must render the static fallback value 24`);
  }
  const visibleText = content.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  if (!visibleText.includes(expectedCopy)) {
    throw new Error(`${label} is missing the approved daily-updated download label`);
  }
}

function verifyHeroDownloadMetadataLayout(label, content) {
  const hero = content.match(/<section class="hero">([\s\S]*?)<\/section>/i)?.[1];
  if (!hero) throw new Error(`${label} is missing the hero section`);

  const facts = hero.match(/<div class="facts"[^>]*>([\s\S]*?)<\/div>/i);
  const downloadCountIndex = hero.indexOf('<p class="download-count"');
  if (!facts || downloadCountIndex === -1) {
    throw new Error(`${label} is missing hero compatibility or download-count metadata`);
  }
  if (facts.index >= downloadCountIndex) {
    throw new Error(`${label} must place compatibility details above the download count`);
  }
  if (/data-release-version/i.test(facts[1])) {
    throw new Error(`${label} must not repeat the release version in hero compatibility details`);
  }
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
