import assert from "node:assert/strict";
import test from "node:test";
import {
  collectStableDmgAssetCounts,
  directEventKey,
  githubDownloadTotal,
  INITIAL_GITHUB_ASSET_LEDGER,
  initialDownloadStats,
  mergeAssetLedger,
  mergePublicStats,
  normalizeAssetLedger,
  normalizePublicStats,
} from "../lib/download-stats-core.js";

test("initial download statistics use the seeded 24 as a floor, not an additive offset", () => {
  assert.deepEqual(initialDownloadStats(), {
    schemaVersion: 1,
    github: 24,
    direct: 0,
    total: 24,
    updatedAt: null,
  });
  assert.deepEqual(INITIAL_GITHUB_ASSET_LEDGER, {
    490267983: 4,
    490069831: 10,
    489731837: 5,
    481319361: 4,
    481294465: 1,
  });
  assert.equal(
    Object.values(INITIAL_GITHUB_ASSET_LEDGER).reduce((sum, count) => sum + count, 0),
    24,
  );
  assert.equal(githubDownloadTotal(INITIAL_GITHUB_ASSET_LEDGER), 24);
  assert.equal(githubDownloadTotal({
    ...INITIAL_GITHUB_ASSET_LEDGER,
    490267983: 10,
  }), 30);
});

test("stable GitHub aggregation includes only valid uploaded DMG assets", () => {
  const releases = [
    {
      draft: false,
      prerelease: false,
      assets: [
        { id: 101, name: "QuitHide-v0.5.0.dmg", state: "uploaded", download_count: 10 },
        { id: 102, name: "QuitHide-v0.4.0.DMG", download_count: 4 },
        { id: 103, name: "QuitHide-v0.5.0.dmg.sha256", download_count: 500 },
        { id: 104, name: "QuitHide-v0.5.0.zip", download_count: 500 },
        { id: 105, name: "QuitHide-v0.5.0.dmg", state: "new", download_count: 500 },
        { id: 106, name: "QuitHide-v0.5.0.dmg", download_count: -1 },
        { id: "107", name: "QuitHide-v0.5.0.dmg", download_count: 500 },
      ],
    },
    {
      draft: false,
      prerelease: false,
      assets: [
        { id: 101, name: "QuitHide-v0.5.0.dmg", download_count: 12 },
      ],
    },
    {
      draft: false,
      prerelease: true,
      assets: [{ id: 201, name: "QuitHide-beta.dmg", download_count: 900 }],
    },
    {
      draft: true,
      prerelease: false,
      assets: [{ id: 202, name: "QuitHide-draft.dmg", download_count: 900 }],
    },
  ];

  assert.deepEqual(collectStableDmgAssetCounts(releases), {
    101: 12,
    102: 4,
  });
  assert.deepEqual(collectStableDmgAssetCounts(null), {});
});

test("the asset ledger preserves disappeared assets and each asset's historical maximum", () => {
  const previous = { 490267983: 10, 490069831: 10 };
  const current = { 490069831: 15, 999: 2 };
  const merged = mergeAssetLedger(previous, current);

  assert.deepEqual(merged, {
    ...INITIAL_GITHUB_ASSET_LEDGER,
    490267983: 10,
    490069831: 15,
    999: 2,
  });
  assert.equal(githubDownloadTotal(mergeAssetLedger(previous, { 490069831: 15 })), 35);
  assert.equal(githubDownloadTotal(mergeAssetLedger(merged, { 490069831: 12 })), 37);
});

test("public statistics never move either source counter backwards", () => {
  const previous = {
    github: 30,
    direct: 7,
    total: 37,
    updatedAt: "2026-07-25T00:00:00.000Z",
  };
  assert.deepEqual(mergePublicStats(previous, {
    github: 24,
    direct: 3,
    updatedAt: "2026-07-26T00:00:00.000Z",
  }), {
    schemaVersion: 1,
    github: 30,
    direct: 7,
    total: 37,
    updatedAt: "2026-07-26T00:00:00.000Z",
  });
});

test("stored data is normalized to safe monotonic defaults", () => {
  assert.deepEqual(normalizeAssetLedger({
    1: 3,
    bad: 9,
    2: -1,
    3: 1.5,
  }), { 1: 3 });
  assert.deepEqual(normalizePublicStats({
    github: 2,
    direct: -4,
    total: 999,
    updatedAt: "not-a-date",
  }), initialDownloadStats());
});

test("direct event keys use the UTC day and unique event id", () => {
  const timestamp = Date.parse("2026-07-26T23:59:58.123Z");
  assert.equal(
    directEventKey(timestamp, "event-123"),
    `events/direct/2026-07-26/${timestamp}-event-123.event`,
  );
  assert.throws(() => directEventKey(Number.NaN, "event-123"), /timestamp/);
  assert.throws(() => directEventKey(timestamp, ""), /event id/);
});
