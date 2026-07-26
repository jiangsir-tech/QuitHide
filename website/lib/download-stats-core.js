export const INITIAL_GITHUB_DOWNLOADS = 24;
export const DIRECT_EVENT_PREFIX = "events/direct/";
export const INITIAL_GITHUB_ASSET_LEDGER = Object.freeze({
  "490267983": 4,
  "490069831": 10,
  "489731837": 5,
  "481319361": 4,
  "481294465": 1,
});

export function initialDownloadStats() {
  return {
    schemaVersion: 1,
    github: INITIAL_GITHUB_DOWNLOADS,
    direct: 0,
    total: INITIAL_GITHUB_DOWNLOADS,
    updatedAt: null,
  };
}

export function collectStableDmgAssetCounts(releases) {
  const counts = {};
  for (const release of Array.isArray(releases) ? releases : []) {
    if (release?.draft || release?.prerelease) continue;
    for (const asset of Array.isArray(release?.assets) ? release.assets : []) {
      if (!asset?.name?.toLowerCase().endsWith(".dmg")) continue;
      if (asset.state && asset.state !== "uploaded") continue;
      if (!Number.isSafeInteger(asset.id) || !Number.isSafeInteger(asset.download_count)) continue;
      if (asset.download_count < 0) continue;
      const id = String(asset.id);
      counts[id] = Math.max(counts[id] ?? 0, asset.download_count);
    }
  }
  return counts;
}

export function mergeAssetLedger(previous, current) {
  const merged = { ...INITIAL_GITHUB_ASSET_LEDGER };
  for (const values of [previous, current]) {
    for (const [id, count] of Object.entries(normalizeAssetLedger(values))) {
      merged[id] = Math.max(merged[id] ?? 0, count);
    }
  }
  return merged;
}

export function githubDownloadTotal(ledger) {
  const total = Object.values(mergeAssetLedger({}, ledger))
    .reduce((sum, count) => sum + count, 0);
  return Math.max(INITIAL_GITHUB_DOWNLOADS, total);
}

export function normalizePublicStats(value) {
  const github = Number.isSafeInteger(value?.github) && value.github >= INITIAL_GITHUB_DOWNLOADS
    ? value.github
    : INITIAL_GITHUB_DOWNLOADS;
  const direct = Number.isSafeInteger(value?.direct) && value.direct >= 0 ? value.direct : 0;
  const updatedAt = typeof value?.updatedAt === "string" && Number.isFinite(Date.parse(value.updatedAt))
    ? value.updatedAt
    : null;
  return { schemaVersion: 1, github, direct, total: github + direct, updatedAt };
}

export function mergePublicStats(previous, candidate) {
  const current = normalizePublicStats(previous);
  const github = Number.isSafeInteger(candidate?.github)
    ? Math.max(current.github, candidate.github, INITIAL_GITHUB_DOWNLOADS)
    : current.github;
  const direct = Number.isSafeInteger(candidate?.direct) && candidate.direct >= 0
    ? Math.max(current.direct, candidate.direct)
    : current.direct;
  const updatedAt = typeof candidate?.updatedAt === "string" && Number.isFinite(Date.parse(candidate.updatedAt))
    ? candidate.updatedAt
    : current.updatedAt;
  return { schemaVersion: 1, github, direct, total: github + direct, updatedAt };
}

export function directEventKey(timestamp, uuid) {
  if (!Number.isFinite(timestamp)) throw new Error("Invalid direct-download event timestamp");
  if (typeof uuid !== "string" || uuid.length === 0) throw new Error("Invalid direct-download event id");
  const day = new Date(timestamp).toISOString().slice(0, 10);
  return `${DIRECT_EVENT_PREFIX}${day}/${timestamp}-${uuid}.event`;
}

export function normalizeAssetLedger(value) {
  const counts = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return counts;
  for (const [id, count] of Object.entries(value)) {
    if (/^\d+$/.test(id) && Number.isSafeInteger(count) && count >= 0) counts[id] = count;
  }
  return counts;
}
