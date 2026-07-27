import assert from "node:assert/strict";
import {
  renderSparkleReleaseNotesHTML,
  synchronizeReleasePublicationDate,
  validateReleaseHistory,
  visibleReleasesAfterBuild,
} from "../lib/release-history-core.mjs";

const history = {
  schemaVersion: 1,
  releases: [
    release("1.0.0", 10, "2026-01-01T00:00:00Z", "第一版", "First release"),
    release("1.0.1", 11, "2026-01-02T00:00:00Z", "第二版", "Second release"),
    release("1.0.2", 12, "2026-01-03T00:00:00Z", "第三版", "Third release"),
  ],
};
const manifest = {
  version: "1.0.2",
  build: 12,
  minimumSystemVersion: "13.0",
  releaseNotes: "第三版",
  releaseNotesEn: "Third release",
  downloadURL: "https://github.com/jiangsir-tech/QuitHide/releases/tag/v1.0.2",
};

validateReleaseHistory(history, { manifest });
validateReleaseHistory(history, {
  currentRelease: {
    version: "1.0.1",
    build: 11,
    minimumSystemVersion: "13.0",
    publishedAt: "2026-01-02T00:00:00Z",
    releaseNotes: {
      "zh-CN": "第二版",
      en: "Second release",
    },
  },
});

assert.deepEqual(
  visibleReleasesAfterBuild(history, 10).map(({ build }) => build),
  [12, 11],
);
assert.deepEqual(
  visibleReleasesAfterBuild(history, 11).map(({ build }) => build),
  [12],
);
assert.deepEqual(
  visibleReleasesAfterBuild(history, 1).map(({ build }) => build),
  [12, 11, 10],
);

const html = renderSparkleReleaseNotesHTML(history, manifest);
assert.ok(html.includes('data-sparkle-version="12"'));
assert.ok(html.includes('data-sparkle-version="11"'));
assert.ok(html.includes('data-sparkle-version="10"'));
assert.ok(
  html.indexOf('data-sparkle-version="12"')
    < html.indexOf('data-sparkle-version="11"'),
);
assert.match(
  html,
  /\.release-entry\.sparkle-installed-version ~ \.release-entry \{ display: none; \}/,
);
assert.ok(html.includes("第三版"));
assert.ok(html.includes("Third release"));

const synchronizedHistory = synchronizeReleasePublicationDate(
  history,
  manifest,
  "2026-01-03T12:34:56Z",
);
assert.equal(
  synchronizedHistory.releases.at(-1).publishedAt,
  "2026-01-03T12:34:56Z",
);
assert.equal(history.releases.at(-1).publishedAt, "2026-01-03T00:00:00Z");

assert.throws(
  () => validateReleaseHistory({
    ...history,
    releases: [history.releases[0], { ...history.releases[1], build: 10 }],
  }),
  /builds must be strictly increasing/,
);
assert.throws(
  () => validateReleaseHistory(history, {
    manifest: { ...manifest, releaseNotes: "不一致" },
  }),
  /does not match update\.json/,
);
assert.throws(
  () => synchronizeReleasePublicationDate(
    history,
    manifest,
    "not-a-publication-date",
  ),
  /valid publication date/,
);

console.log("PASS: adaptive cumulative Sparkle release notes");

function release(version, build, publishedAt, chinese, english) {
  return {
    version,
    build,
    minimumSystemVersion: "13.0",
    publishedAt,
    releaseNotes: {
      "zh-CN": chinese,
      en: english,
    },
  };
}
