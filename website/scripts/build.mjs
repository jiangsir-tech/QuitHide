import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { INITIAL_GITHUB_DOWNLOADS } from "../lib/download-stats-core.js";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const websiteDirectory = path.resolve(scriptDirectory, "..");
const sourceDirectory = path.join(websiteDirectory, "src");
const outputDirectory = path.join(websiteDirectory, "dist");
const releasePath = path.join(websiteDirectory, "release.json");

const release = JSON.parse(await readFile(releasePath, "utf8"));
validateRelease(release);

const siteURL = normalizeSiteURL(
  process.env.QUITHIDE_SITE_URL || "http://localhost:4173",
);
const releaseFeedURL =
  process.env.QUITHIDE_RELEASE_FEED_URL || `${siteURL}/release.json`;

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });
await cp(sourceDirectory, outputDirectory, { recursive: true });

const replacements = {
  "{{SITE_URL}}": siteURL,
  "{{RELEASE_FEED_URL}}": releaseFeedURL,
  "{{VERSION}}": release.version,
  "{{BUILD}}": String(release.build),
  "{{MINIMUM_SYSTEM_VERSION}}": release.minimumSystemVersion,
  "{{PUBLISHED_DATE_ZH}}": formatDate(release.publishedAt, "zh-CN"),
  "{{PUBLISHED_DATE_EN}}": formatDate(release.publishedAt, "en-US"),
  "{{RELEASE_NOTES_ZH}}": escapeHTML(release.releaseNotes["zh-CN"]),
  "{{RELEASE_NOTES_EN}}": escapeHTML(release.releaseNotes.en),
  "{{FILE_NAME}}": release.file.name,
  "{{FILE_SIZE}}": formatBytes(release.file.size),
  "{{SHA256}}": release.file.sha256,
  "{{DIRECT_DOWNLOAD_URL}}": release.file.directDownloadURL,
  "{{GITHUB_RELEASE_URL}}": release.githubReleaseURL,
  "{{GITHUB_DOWNLOAD_URL}}": release.file.githubDownloadURL,
  "{{DOWNLOAD_TOTAL_FALLBACK}}": String(INITIAL_GITHUB_DOWNLOADS),
  "{{SOFTWARE_JSON_LD_ZH}}": JSON.stringify(
    softwareJSONLD(release, siteURL, "zh-CN"),
  ).replaceAll("<", "\\u003c"),
  "{{SOFTWARE_JSON_LD_EN}}": JSON.stringify(
    softwareJSONLD(release, siteURL, "en"),
  ).replaceAll("<", "\\u003c"),
};

for (const relativePath of [
  "index.html",
  "en/index.html",
  "robots.txt",
  "sitemap.xml",
]) {
  const target = path.join(outputDirectory, relativePath);
  let content = await readFile(target, "utf8");
  for (const [token, value] of Object.entries(replacements)) {
    content = content.replaceAll(token, value);
  }
  if (/\{\{[A-Z0-9_]+\}\}/.test(content)) {
    throw new Error(`Unresolved template token in ${relativePath}`);
  }
  await writeFile(target, content);
}

await writeFile(
  path.join(outputDirectory, "release.json"),
  `${JSON.stringify(release, null, 2)}\n`,
);

console.log(`Built QuitHide product site for v${release.version} at ${siteURL}`);

function validateRelease(value) {
  const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
  const shaPattern = /^[a-f0-9]{64}$/;
  if (!versionPattern.test(value?.version)) throw new Error("Invalid release version");
  if (!Number.isInteger(value?.build) || value.build < 0) throw new Error("Invalid build");
  if (!/^\d+\.\d+(?:\.\d+)?$/.test(value?.minimumSystemVersion)) {
    throw new Error("Invalid minimum system version");
  }
  if (!value?.releaseNotes?.["zh-CN"] || !value?.releaseNotes?.en) {
    throw new Error("Missing bilingual release notes");
  }
  if (!Number.isInteger(value?.file?.size) || value.file.size <= 0) {
    throw new Error("Invalid release file size");
  }
  if (!shaPattern.test(value?.file?.sha256)) throw new Error("Invalid SHA-256");
  for (const candidate of [
    value.githubReleaseURL,
    value.file.directDownloadURL,
    value.file.githubDownloadURL,
  ]) {
    const url = new URL(candidate);
    if (url.protocol !== "https:") throw new Error("Release URLs must use HTTPS");
  }
}

function normalizeSiteURL(value) {
  const url = new URL(value);
  if (!new Set(["http:", "https:"]).has(url.protocol)) {
    throw new Error("Site URL must use HTTP or HTTPS");
  }
  return url.toString().replace(/\/$/, "");
}

function formatDate(value, locale) {
  return new Intl.DateTimeFormat(locale, {
    year: "numeric",
    month: locale === "zh-CN" ? "long" : "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(value));
}

function formatBytes(bytes) {
  return `${(bytes / 1_000_000).toFixed(2)} MB`;
}

function escapeHTML(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function softwareJSONLD(value, baseURL, language) {
  const isChinese = language === "zh-CN";
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "QuitHide",
    applicationCategory: "UtilitiesApplication",
    operatingSystem: "macOS 13 or later",
    softwareVersion: value.version,
    inLanguage: language,
    description: isChinese
      ? "自动隐藏或正常退出一段时间未使用的 Mac App。"
      : "Automatically hide or normally quit Mac apps after they stay in the background.",
    downloadUrl: value.file.directDownloadURL,
    releaseNotes: value.releaseNotes[language],
    datePublished: value.publishedAt,
    fileSize: formatBytes(value.file.size),
    isAccessibleForFree: true,
    license: "https://opensource.org/license/mit",
    url: isChinese ? baseURL : `${baseURL}/en/`,
  };
}
