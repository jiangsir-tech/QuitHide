import assert from "node:assert/strict";
import test from "node:test";
import {
  aggregateDirectDownloadEvents,
  createDirectDownloadEventResponse,
  createPublicStatsResponse,
  DIRECT_DAILY_PREFIX,
  fetchStableDmgAssetCounts,
  GITHUB_LEDGER_KEY,
  PUBLIC_STATS_KEY,
  refreshDownloadStats,
} from "../lib/download-stats-service.js";

test("the public endpoint returns a safe 24 fallback for missing or malformed data", async (t) => {
  for (const [label, store] of [
    ["missing object", fakeStore()],
    ["malformed object", fakeStore({ values: { [PUBLIC_STATS_KEY]: { github: 2, direct: -1 } } })],
  ]) {
    await t.test(label, async () => {
      const response = await createPublicStatsResponse(store);
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), {
        schemaVersion: 1,
        github: 24,
        direct: 0,
        total: 24,
        updatedAt: null,
      });
      assert.match(response.headers.get("cache-control"), /stale-if-error/);
      assert.deepEqual(store.calls.get[0], {
        key: PUBLIC_STATS_KEY,
        options: { type: "json", consistency: "strong" },
      });
    });
  }
});

test("the public endpoint exposes a retriable error when strong storage reads fail", async () => {
  const store = fakeStore({ getError: new Error("storage unavailable") });
  const response = await createPublicStatsResponse(store);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "Download stats are temporarily unavailable",
  });
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("a direct click writes one anonymous unique event and immediately returns 204", async () => {
  const store = fakeStore();
  const timestamp = Date.parse("2026-07-26T12:00:00.000Z");
  let backgroundWrite;
  const response = createDirectDownloadEventResponse({
    store,
    waitUntil(promise) { backgroundWrite = promise; },
    now: () => timestamp,
    uuid: () => "unique-event",
  });

  assert.equal(response.status, 204);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.ok(backgroundWrite instanceof Promise);
  await backgroundWrite;
  assert.deepEqual(store.calls.set, [{
    key: `events/direct/2026-07-26/${timestamp}-unique-event.event`,
    value: "",
    options: { onlyIfNew: true, cacheControl: null },
  }]);
});

test("direct-click storage failure is best effort", async () => {
  const store = fakeStore({ setError: new Error("write failed") });
  let backgroundWrite;
  const response = createDirectDownloadEventResponse({
    store,
    waitUntil(promise) { backgroundWrite = promise; },
    now: () => Date.parse("2026-07-26T12:00:00.000Z"),
    uuid: () => "failed-event",
  });
  assert.equal(response.status, 204);
  await assert.doesNotReject(backgroundWrite);
});

test("refresh preserves disappeared GitHub assets while accepting growth on remaining assets", async () => {
  const timestamp = Date.parse("2026-07-26T13:00:00.000Z");
  const store = fakeStore({
    values: {
      [PUBLIC_STATS_KEY]: {
        schemaVersion: 1,
        github: 30,
        direct: 0,
        total: 30,
        updatedAt: null,
      },
      [GITHUB_LEDGER_KEY]: {
        assets: { 490267983: 10, 490069831: 10 },
        updatedAt: "2026-07-25T00:00:00.000Z",
      },
    },
    blobs: [
      "events/direct/2026-07-26/a.event",
      "events/direct/2026-07-26/b.event",
      "events/direct/2026-07-26/c.event",
    ],
  });
  const requested = [];
  const stats = await refreshDownloadStats({
    store,
    now: () => timestamp,
    fetchImpl: async (url) => {
      requested.push(url);
      return okJSON([{
        draft: false,
        prerelease: false,
        assets: [{ id: 490069831, name: "QuitHide-v0.5.0.dmg", download_count: 15 }],
      }]);
    },
  });

  assert.equal(requested.length, 1);
  assert.deepEqual(stats, {
    schemaVersion: 1,
    github: 35,
    direct: 3,
    total: 38,
    updatedAt: "2026-07-26T13:00:00.000Z",
  });
  assert.deepEqual(store.values.get(GITHUB_LEDGER_KEY), {
    assets: {
      490267983: 10,
      490069831: 15,
      489731837: 5,
      481319361: 4,
      481294465: 1,
    },
    updatedAt: "2026-07-26T13:00:00.000Z",
  });
  assert.deepEqual(store.values.get(PUBLIC_STATS_KEY), stats);
  assert.deepEqual(store.calls.list, [{
    prefix: "events/direct/",
    consistency: "strong",
  }, {
    prefix: DIRECT_DAILY_PREFIX,
    consistency: "strong",
  }]);
  assert.ok(store.calls.get.every(({ options }) => options.consistency === "strong"));
});

test("a total source outage returns the last public value and writes no zeroes", async () => {
  const previous = {
    schemaVersion: 1,
    github: 30,
    direct: 4,
    total: 34,
    updatedAt: "2026-07-20T00:00:00.000Z",
  };
  const store = fakeStore({
    values: {
      [PUBLIC_STATS_KEY]: previous,
      [GITHUB_LEDGER_KEY]: { assets: { 1: 30 } },
    },
    listError: new Error("list failed"),
  });
  const stats = await refreshDownloadStats({
    store,
    now: () => Date.parse("2026-07-26T13:00:00.000Z"),
    fetchImpl: async () => { throw new Error("GitHub unavailable"); },
  });

  assert.deepEqual(stats, previous);
  assert.deepEqual(store.calls.setJSON, []);
});

test("a public-state read failure aborts refresh before any aggregation or writes", async () => {
  const store = fakeStore({ getError: new Error("strong read failed") });
  await assert.rejects(refreshDownloadStats({
    store,
    now: () => Date.parse("2026-07-26T13:00:00.000Z"),
    fetchImpl: async () => okJSON([]),
  }), /strong read failed/);
  assert.deepEqual(store.calls.list, []);
  assert.deepEqual(store.calls.setJSON, []);
  assert.deepEqual(store.calls.delete, []);
});

test("old direct events roll up once while recent events remain raw", async () => {
  const store = fakeStore({
    values: {
      [`${DIRECT_DAILY_PREFIX}2026-07-19.json`]: {
        schemaVersion: 1,
        day: "2026-07-19",
        count: 3,
      },
    },
    blobs: [
      "events/direct/2026-07-20/a.event",
      "events/direct/2026-07-20/b.event",
      "events/direct/2026-07-25/c.event",
    ],
  });
  const timestamp = Date.parse("2026-07-26T13:00:00.000Z");

  assert.equal(await aggregateDirectDownloadEvents({ store, timestamp }), 6);
  assert.deepEqual(store.values.get(`${DIRECT_DAILY_PREFIX}2026-07-20.json`), {
    schemaVersion: 1,
    day: "2026-07-20",
    count: 2,
  });
  assert.deepEqual(store.calls.delete.sort(), [
    "events/direct/2026-07-20/a.event",
    "events/direct/2026-07-20/b.event",
  ]);
  assert.equal(await aggregateDirectDownloadEvents({ store, timestamp }), 6);
});

test("fresh daily statistics skip GitHub, event listing, and writes", async () => {
  const now = Date.parse("2026-07-26T13:00:00.000Z");
  const current = {
    schemaVersion: 1,
    github: 30,
    direct: 4,
    total: 34,
    updatedAt: new Date(now - 60_000).toISOString(),
  };
  const store = fakeStore({ values: { [PUBLIC_STATS_KEY]: current } });
  const stats = await refreshDownloadStats({
    store,
    now: () => now,
    fetchImpl: async () => { throw new Error("GitHub should not be called"); },
  });

  assert.deepEqual(stats, current);
  assert.deepEqual(store.calls.list, []);
  assert.deepEqual(store.calls.setJSON, []);
  assert.equal(store.calls.get.length, 1);
});

test("GitHub release pagination aggregates stable DMGs across pages", async () => {
  const pages = {
    1: Array.from({ length: 100 }, (_, index) => ({
      draft: false,
      prerelease: false,
      assets: index === 0
        ? [{ id: 1, name: "QuitHide-v0.4.0.dmg", download_count: 10 }]
        : [],
    })),
    2: [{
      draft: false,
      prerelease: false,
      assets: [{ id: 2, name: "QuitHide-v0.5.0.dmg", download_count: 14 }],
    }],
  };
  const requestedPages = [];
  const counts = await fetchStableDmgAssetCounts(async (url, options) => {
    const page = Number(new URL(url).searchParams.get("page"));
    requestedPages.push(page);
    assert.equal(options.headers.Accept, "application/vnd.github+json");
    assert.equal(options.headers["User-Agent"], "QuitHide-download-stats");
    assert.equal(options.headers.Authorization, undefined);
    return okJSON(pages[page]);
  });

  assert.deepEqual(requestedPages, [1, 2]);
  assert.deepEqual(counts, { 1: 10, 2: 14 });
});

test("GitHub aggregation uses an optional read-only API token", async () => {
  await fetchStableDmgAssetCounts(async (_url, options) => {
    assert.equal(options.headers.Authorization, "Bearer test-token");
    return okJSON([]);
  }, { githubToken: "test-token" });
});

function fakeStore({
  values = {},
  blobs = [],
  getError = null,
  listError = null,
  setError = null,
} = {}) {
  const records = new Map(Object.entries(values).map(([key, value]) => [key, clone(value)]));
  const blobKeys = new Set([...records.keys(), ...blobs]);
  const calls = { get: [], list: [], set: [], setJSON: [], delete: [] };
  return {
    calls,
    values: records,
    async get(key, options) {
      calls.get.push({ key, options });
      if (getError) throw getError;
      return records.has(key) ? clone(records.get(key)) : null;
    },
    async list(options) {
      calls.list.push(options);
      if (listError) throw listError;
      return {
        blobs: [...blobKeys]
          .filter((key) => key.startsWith(options?.prefix ?? ""))
          .map((key) => ({ key })),
      };
    },
    async set(key, value, options) {
      calls.set.push({ key, value, options });
      if (setError) throw setError;
      records.set(key, value);
      blobKeys.add(key);
    },
    async setJSON(key, value, options) {
      calls.setJSON.push({ key, value: clone(value), options });
      if (setError) throw setError;
      if (options?.onlyIfNew && records.has(key)) {
        const error = new Error("already exists");
        error.code = "PRECONDITION_FAILED";
        throw error;
      }
      records.set(key, clone(value));
      blobKeys.add(key);
    },
    async delete(key) {
      calls.delete.push(key);
      records.delete(key);
      blobKeys.delete(key);
    },
  };
}

function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

function okJSON(value) {
  return { ok: true, status: 200, json: async () => value };
}
