import {
  collectStableDmgAssetCounts,
  DIRECT_EVENT_SLOT_COUNT,
  directEventKey,
  DIRECT_EVENT_PREFIX,
  estimateDirectEventSlotCount,
  githubDownloadTotal,
  mergeAssetLedger,
  mergePublicStats,
  normalizeAssetLedger,
  normalizePublicStats,
} from "./download-stats-core.js";

export const DOWNLOAD_STATS_STORE = "quithide-download-stats";
export const GITHUB_LEDGER_KEY = "state/github-assets.json";
export const PUBLIC_STATS_KEY = "public/download-stats.json";
export const DIRECT_DAILY_PREFIX = "daily/direct/";
export const REFRESH_ATTEMPT_PREFIX = "refresh/attempts/";
export const MINIMUM_REFRESH_INTERVAL_MS = 20 * 60 * 60 * 1000;

const GITHUB_RELEASES_API = "https://api.github.com/repos/jiangsir-tech/QuitHide/releases";
const DAY_MS = 24 * 60 * 60 * 1000;

export function createDirectDownloadEventResponse({
  store,
  waitUntil,
  now = () => Date.now(),
  uuid = () => crypto.randomUUID(),
}) {
  const timestamp = now();
  const key = directEventKey(timestamp, uuid());
  const write = Promise.resolve()
    .then(() => store.set(key, "", { onlyIfNew: true, cacheControl: null }))
    .catch(() => undefined);

  try {
    waitUntil?.(write);
  } catch {
    // Counting is best effort and never changes the actual download link.
  }

  return new Response(null, {
    status: 204,
    headers: { "Cache-Control": "no-store" },
  });
}

export async function createPublicStatsResponse(store) {
  try {
    const stats = normalizePublicStats(await readJSON(store, PUBLIC_STATS_KEY));
    return jsonResponse(stats, {
      "Cache-Control": "public, max-age=300, stale-while-revalidate=86400, stale-if-error=604800",
    });
  } catch {
    return jsonResponse({ error: "Download stats are temporarily unavailable" }, {
      "Cache-Control": "no-store",
    }, 503);
  }
}

export async function createRefreshResponse({
  store,
  fetchImpl = fetch,
  githubToken,
  now = () => Date.now(),
}) {
  const stats = await refreshDownloadStats({ store, fetchImpl, githubToken, now });
  return jsonResponse(stats, { "Cache-Control": "no-store" });
}

export async function refreshDownloadStats({
  store,
  fetchImpl = fetch,
  githubToken,
  now = () => Date.now(),
}) {
  const timestamp = now();
  const previousStats = await readPublicStats(store);
  if (isFresh(previousStats.updatedAt, timestamp)) return previousStats;
  if (!await acquireRefreshAttempt(store, timestamp)) return previousStats;

  const [ledgerResult, githubResult, directResult] = await Promise.allSettled([
    readJSON(store, GITHUB_LEDGER_KEY),
    fetchStableDmgAssetCounts(fetchImpl, { githubToken }),
    aggregateDirectDownloadEvents({ store, timestamp }),
  ]);

  let github = previousStats.github;
  let nextLedger = null;
  if (githubResult.status === "fulfilled") {
    if (ledgerResult.status === "fulfilled") {
      nextLedger = mergeAssetLedger(ledgerResult.value?.assets, githubResult.value);
      github = Math.max(previousStats.github, githubDownloadTotal(nextLedger));
    } else {
      github = Math.max(previousStats.github, githubDownloadTotal(githubResult.value));
    }
  }

  let direct = previousStats.direct;
  if (directResult.status === "fulfilled") {
    direct = Math.max(previousStats.direct, directResult.value);
  }

  if (githubResult.status === "rejected" && directResult.status === "rejected") {
    return previousStats;
  }

  const updatedAt = new Date(timestamp).toISOString();
  const stats = mergePublicStats(previousStats, { github, direct, updatedAt });
  if (nextLedger) {
    await store.setJSON(GITHUB_LEDGER_KEY, {
      assets: normalizeAssetLedger(nextLedger),
      updatedAt,
    });
  }
  await store.setJSON(PUBLIC_STATS_KEY, stats);
  return stats;
}

export async function fetchStableDmgAssetCounts(fetchImpl, { githubToken } = {}) {
  const releases = [];
  for (let page = 1; page <= 10; page += 1) {
    const headers = {
        Accept: "application/vnd.github+json",
        "User-Agent": "QuitHide-download-stats",
        "X-GitHub-Api-Version": "2026-03-10",
    };
    if (githubToken) headers.Authorization = `Bearer ${githubToken}`;
    const response = await fetchImpl(`${GITHUB_RELEASES_API}?per_page=100&page=${page}`, {
      headers,
    });
    if (!response.ok) throw new Error(`GitHub releases returned ${response.status}`);
    const values = await response.json();
    if (!Array.isArray(values)) throw new Error("Invalid GitHub releases response");
    releases.push(...values);
    if (values.length < 100) return collectStableDmgAssetCounts(releases);
  }
  throw new Error("GitHub releases exceeded the supported pagination limit");
}

export async function aggregateDirectDownloadEvents({ store, timestamp }) {
  const [eventListing, dailyListing] = await Promise.all([
    store.list({ prefix: DIRECT_EVENT_PREFIX, consistency: "strong" }),
    store.list({ prefix: DIRECT_DAILY_PREFIX, consistency: "strong" }),
  ]);
  const eventsByDay = groupEventKeysByDay(eventListing?.blobs);
  const dailyCounts = await readDailyCounts(store, dailyListing?.blobs);
  const archiveBeforeDay = new Date(timestamp - (2 * DAY_MS)).toISOString().slice(0, 10);

  for (const [day, group] of eventsByDay) {
    if (day >= archiveBeforeDay) continue;
    if (!dailyCounts.has(day)) {
      const count = await createOrReadDailyCount(store, day, directEventCount(group));
      dailyCounts.set(day, count);
    }
    await deleteBestEffort(store, group.keys);
  }

  let direct = [...dailyCounts.values()].reduce((sum, count) => sum + count, 0);
  for (const [day, group] of eventsByDay) {
    if (!dailyCounts.has(day)) direct += directEventCount(group);
  }
  return direct;
}

async function readPublicStats(store) {
  return normalizePublicStats(await readJSON(store, PUBLIC_STATS_KEY));
}

function readJSON(store, key) {
  return store.get(key, { type: "json", consistency: "strong" });
}

function isFresh(updatedAt, timestamp) {
  if (!updatedAt) return false;
  const previous = Date.parse(updatedAt);
  return Number.isFinite(previous) && timestamp - previous < MINIMUM_REFRESH_INTERVAL_MS;
}

async function acquireRefreshAttempt(store, timestamp) {
  const window = Math.floor(timestamp / MINIMUM_REFRESH_INTERVAL_MS);
  const key = `${REFRESH_ATTEMPT_PREFIX}${window}.lock`;
  try {
    await store.set(key, "", { onlyIfNew: true, cacheControl: null });
    return true;
  } catch (error) {
    if (error?.code === "PRECONDITION_FAILED") return false;
    throw error;
  }
}

function groupEventKeysByDay(blobs) {
  const values = new Map();
  for (const blob of Array.isArray(blobs) ? blobs : []) {
    const match = blob?.key?.match(/^events\/direct\/(\d{4}-\d{2}-\d{2})\/(.+)$/);
    if (!match) continue;
    const group = values.get(match[1]) ?? {
      keys: [],
      legacyCount: 0,
      slots: new Set(),
    };
    group.keys.push(blob.key);
    const slotMatch = match[2].match(/^slot-(\d{4})\.event$/);
    const slot = slotMatch ? Number(slotMatch[1]) : Number.NaN;
    if (Number.isSafeInteger(slot) && slot >= 0 && slot < DIRECT_EVENT_SLOT_COUNT) {
      group.slots.add(slot);
    } else {
      group.legacyCount += 1;
    }
    values.set(match[1], group);
  }
  return values;
}

function directEventCount(group) {
  return group.legacyCount + estimateDirectEventSlotCount(group.slots.size);
}

async function readDailyCounts(store, blobs) {
  const values = new Map();
  for (const blob of Array.isArray(blobs) ? blobs : []) {
    const match = blob?.key?.match(/^daily\/direct\/(\d{4}-\d{2}-\d{2})\.json$/);
    if (!match) continue;
    const summary = await readJSON(store, blob.key);
    if (
      summary?.day !== match[1] ||
      !Number.isSafeInteger(summary?.count) ||
      summary.count < 0
    ) {
      throw new Error(`Invalid direct-download summary: ${blob.key}`);
    }
    values.set(match[1], summary.count);
  }
  return values;
}

async function createOrReadDailyCount(store, day, count) {
  const key = `${DIRECT_DAILY_PREFIX}${day}.json`;
  const summary = { schemaVersion: 1, day, count };
  try {
    await store.setJSON(key, summary, { onlyIfNew: true, cacheControl: null });
    return count;
  } catch (error) {
    if (error?.code !== "PRECONDITION_FAILED") throw error;
    const existing = await readJSON(store, key);
    if (existing?.day !== day || !Number.isSafeInteger(existing?.count) || existing.count < 0) {
      throw new Error(`Invalid existing direct-download summary: ${key}`);
    }
    return existing.count;
  }
}

async function deleteBestEffort(store, keys) {
  const batchSize = 50;
  for (let index = 0; index < keys.length; index += batchSize) {
    await Promise.allSettled(keys.slice(index, index + batchSize).map((key) => store.delete(key)));
  }
}

function jsonResponse(value, extraHeaders, status = 200) {
  return new Response(`${JSON.stringify(value)}\n`, {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}
