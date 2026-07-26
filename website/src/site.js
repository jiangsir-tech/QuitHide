import {
  installDirectDownloadLogging,
  refreshDownloadStats,
} from "./download-stats-client.js";

const root = document.documentElement;
const feedURL = document.body.dataset.releaseFeed;
const downloadEventURL = document.body.dataset.downloadEvent;
const downloadStatsURL = document.body.dataset.downloadStats;
const locale = root.lang === "en" ? "en" : "zh-CN";

if (feedURL) refreshRelease(feedURL).catch(() => {
  document.body.dataset.releaseStatus = "static";
});

if (downloadStatsURL) {
  refreshDownloadStats({
    root: document,
    url: downloadStatsURL,
    locale,
  }).then((updated) => {
    document.body.dataset.downloadStatsStatus = updated ? "live" : "static";
  }).catch(() => {
    document.body.dataset.downloadStatsStatus = "static";
  });
}

if (downloadEventURL) {
  installDirectDownloadLogging({ root: document, url: downloadEventURL });
}

async function refreshRelease(url) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 5000);
  const response = await fetch(url, {
    cache: "no-store",
    headers: { Accept: "application/json" },
    signal: controller.signal,
  });
  window.clearTimeout(timeout);
  if (!response.ok) throw new Error(`Release feed returned ${response.status}`);
  const release = await response.json();
  validateRelease(release);

  setText("[data-release-version]", `v${release.version}`);
  setText("[data-release-size]", formatBytes(release.file.size));
  setText("[data-release-sha]", release.file.sha256);
  setText(
    "[data-release-date]",
    new Intl.DateTimeFormat(locale, {
      year: "numeric",
      month: locale === "zh-CN" ? "long" : "short",
      day: "numeric",
    }).format(new Date(release.publishedAt)),
  );
  setText("[data-release-notes]", release.releaseNotes[locale]);
  setLink("[data-direct-download]", release.file.directDownloadURL);
  setLink("[data-github-release]", release.githubReleaseURL);
  document.body.dataset.releaseStatus = "live";
}

function validateRelease(value) {
  if (!/^\d+\.\d+\.\d+$/.test(value?.version)) throw new Error("Invalid version");
  if (!/^[a-f0-9]{64}$/.test(value?.file?.sha256)) throw new Error("Invalid checksum");
  for (const candidate of [value.file.directDownloadURL, value.githubReleaseURL]) {
    if (new URL(candidate).protocol !== "https:") throw new Error("Invalid release URL");
  }
  if (!value?.releaseNotes?.[locale]) throw new Error("Missing release notes");
}

function setText(selector, value) {
  document.querySelectorAll(selector).forEach((element) => {
    element.textContent = value;
  });
}

function setLink(selector, value) {
  document.querySelectorAll(selector).forEach((element) => {
    element.href = value;
  });
}

function formatBytes(bytes) {
  return `${(bytes / 1_000_000).toFixed(2)} MB`;
}
