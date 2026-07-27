const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const minimumSystemPattern = /^\d+\.\d+(?:\.\d+)?$/;
const publishedAtPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

export function validateReleaseHistory(value, options = {}) {
  if (value?.schemaVersion !== 1 || !Array.isArray(value?.releases)) {
    throw new Error("release-history.json must use schemaVersion 1 and a releases array");
  }
  if (value.releases.length === 0) {
    throw new Error("release-history.json must contain at least one release");
  }

  const releases = value.releases.map((release, index) => {
    const label = `release-history.json releases[${index}]`;
    if (!versionPattern.test(release?.version)) {
      throw new Error(`Invalid version in ${label}`);
    }
    if (!Number.isInteger(release?.build) || release.build <= 0) {
      throw new Error(`Invalid build in ${label}`);
    }
    if (!minimumSystemPattern.test(release?.minimumSystemVersion)) {
      throw new Error(`Invalid minimum system version in ${label}`);
    }
    if (
      !publishedAtPattern.test(release?.publishedAt)
      || Number.isNaN(Date.parse(release.publishedAt))
    ) {
      throw new Error(`Invalid publication date in ${label}`);
    }
    if (
      !release?.releaseNotes?.["zh-CN"]?.trim()
      || !release?.releaseNotes?.en?.trim()
    ) {
      throw new Error(`Missing bilingual release notes in ${label}`);
    }
    return release;
  });

  for (let index = 1; index < releases.length; index += 1) {
    const previous = releases[index - 1];
    const current = releases[index];
    if (compareSemanticVersions(previous.version, current.version) >= 0) {
      throw new Error("Release-history versions must be strictly increasing");
    }
    if (previous.build >= current.build) {
      throw new Error("Release-history builds must be strictly increasing");
    }
    if (Date.parse(previous.publishedAt) >= Date.parse(current.publishedAt)) {
      throw new Error("Release-history publication dates must be strictly increasing");
    }
  }

  if (options.manifest) {
    validateLatestAgainstManifest(releases.at(-1), options.manifest);
  }
  if (options.currentRelease) {
    validatePublicReleaseAgainstHistory(releases, options.currentRelease);
  }
  return releases;
}

export function renderSparkleReleaseNotesHTML(history, manifest) {
  const releases = validateReleaseHistory(history, { manifest });
  const entries = [...releases]
    .reverse()
    .map((release) => `
  <section class="release-entry" data-sparkle-version="${release.build}" data-release-version="${escapeHTML(release.version)}">
    <h2>QuitHide ${escapeHTML(release.version)}</h2>
    <div lang="zh-CN">
      <h3>简体中文</h3>
      ${renderParagraphs(release.releaseNotes["zh-CN"])}
    </div>
    <div lang="en">
      <h3>English</h3>
      ${renderParagraphs(release.releaseNotes.en)}
    </div>
  </section>`)
    .join("\n");

  return `<style>
.release-history { line-height: 1.55; }
.release-intro { margin: 0 0 16px; opacity: 0.72; }
.release-entry { padding: 4px 0 18px; }
.release-entry + .release-entry { padding-top: 18px; border-top: 1px solid rgba(127, 127, 127, 0.28); }
.release-entry h2 { margin: 0 0 12px; font-size: 1.28em; }
.release-entry h3 { margin: 12px 0 5px; font-size: 1em; }
.release-entry p { margin: 0; }
.release-entry.sparkle-installed-version,
.release-entry.sparkle-installed-version ~ .release-entry { display: none; }
</style>
<div class="release-history">
  <p class="release-intro">以下为你当前版本之后包含的更新。<br><span lang="en">These are the updates included after your currently installed version.</span></p>
${entries}
</div>`;
}

export function visibleReleasesAfterBuild(history, installedBuild) {
  const releases = validateReleaseHistory(history);
  if (!Number.isInteger(installedBuild) || installedBuild < 0) {
    throw new Error("Installed build must be a non-negative integer");
  }
  return releases.filter((release) => release.build > installedBuild).reverse();
}

export function synchronizeReleasePublicationDate(history, manifest, publishedAt) {
  const releases = validateReleaseHistory(history, { manifest });
  if (
    !publishedAtPattern.test(publishedAt)
    || Number.isNaN(Date.parse(publishedAt))
  ) {
    throw new Error("Published release requires a valid publication date");
  }
  const updatedHistory = {
    ...history,
    releases: releases.map((release, index) => (
      index === releases.length - 1
        ? { ...release, publishedAt }
        : release
    )),
  };
  validateReleaseHistory(updatedHistory, { manifest });
  return updatedHistory;
}

export function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function renderParagraphs(value) {
  return value
    .trim()
    .split(/\n\s*\n/)
    .map((paragraph) => `<p>${escapeHTML(paragraph).replaceAll("\n", "<br>")}</p>`)
    .join("\n      ");
}

function validateLatestAgainstManifest(latest, manifest) {
  const expectedDownloadURL =
    `https://github.com/jiangsir-tech/QuitHide/releases/tag/v${latest.version}`;
  const matches = (
    latest.version === manifest?.version
    && latest.build === manifest?.build
    && latest.minimumSystemVersion === manifest?.minimumSystemVersion
    && latest.releaseNotes["zh-CN"] === manifest?.releaseNotes
    && latest.releaseNotes.en === manifest?.releaseNotesEn
    && manifest?.downloadURL === expectedDownloadURL
  );
  if (!matches) {
    throw new Error("Latest release-history entry does not match update.json");
  }
}

function validatePublicReleaseAgainstHistory(releases, currentRelease) {
  const matchingReleases = releases.filter((release) => (
    release.version === currentRelease?.version
    && release.build === currentRelease?.build
  ));
  if (matchingReleases.length !== 1) {
    throw new Error("website/release.json does not identify exactly one release-history entry");
  }
  const release = matchingReleases[0];
  const metadataMatches = (
    release.minimumSystemVersion === currentRelease?.minimumSystemVersion
    && release.publishedAt === currentRelease?.publishedAt
    && release.releaseNotes["zh-CN"] === currentRelease?.releaseNotes?.["zh-CN"]
    && release.releaseNotes.en === currentRelease?.releaseNotes?.en
  );
  if (!metadataMatches) {
    throw new Error("release-history entry does not match website/release.json");
  }
}

function compareSemanticVersions(left, right) {
  const leftComponents = left.split(".").map(Number);
  const rightComponents = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftComponents[index] !== rightComponents[index]) {
      return Math.sign(leftComponents[index] - rightComponents[index]);
    }
  }
  return 0;
}
