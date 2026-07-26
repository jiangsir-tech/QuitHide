import assert from "node:assert/strict";
import test from "node:test";
import {
  installDirectDownloadLogging,
  refreshDownloadStats,
} from "../src/download-stats-client.js";

test("a valid stats response replaces the static count without blanking it while pending", async () => {
  const counters = [fakeCounter(24), fakeCounter(24)];
  let resolveFetch;
  const operation = refreshDownloadStats({
    root: fakeRoot({ counters }),
    url: "/api/download-stats",
    locale: "en-US",
    fetchImpl: (url, options) => {
      assert.equal(url, "/api/download-stats");
      assert.deepEqual(options, {
        cache: "no-store",
        credentials: "omit",
        headers: { Accept: "application/json" },
      });
      return new Promise((resolve) => { resolveFetch = resolve; });
    },
  });

  assert.deepEqual(counters.map(({ textContent }) => textContent), ["24", "24"]);
  resolveFetch(okJSON({ total: 1_234 }));
  assert.equal(await operation, true);
  assert.deepEqual(counters.map(({ textContent }) => textContent), ["1,234", "1,234"]);
  assert.deepEqual(counters.map(({ dataset }) => dataset.downloadCount), ["1234", "1234"]);
});

test("invalid or decreasing responses retain the last static number", async (t) => {
  for (const [label, payload] of [
    ["missing total", {}],
    ["string total", { total: "41" }],
    ["fractional total", { total: 41.5 }],
    ["negative total", { total: -1 }],
    ["decreasing total", { total: 36 }],
  ]) {
    await t.test(label, async () => {
      const counter = fakeCounter(37);
      const updated = await refreshDownloadStats({
        root: fakeRoot({ counters: [counter] }),
        url: "/api/download-stats",
        locale: "en-US",
        fetchImpl: async () => okJSON(payload),
      });
      assert.equal(updated, false);
      assert.equal(counter.dataset.downloadCount, "37");
      assert.equal(counter.textContent, "37");
    });
  }
});

test("network, HTTP, and JSON failures leave the original 24 visible", async (t) => {
  for (const [label, fetchImpl] of [
    ["network failure", async () => { throw new Error("offline"); }],
    ["HTTP failure", async () => ({ ok: false, status: 503 })],
    ["JSON failure", async () => ({ ok: true, json: async () => { throw new Error("bad json"); } })],
  ]) {
    await t.test(label, async () => {
      const counter = fakeCounter(24);
      await assert.rejects(refreshDownloadStats({
        root: fakeRoot({ counters: [counter] }),
        url: "/api/download-stats",
        locale: "zh-CN",
        fetchImpl,
      }));
      assert.equal(counter.dataset.downloadCount, "24");
      assert.equal(counter.textContent, "24");
    });
  }
});

test("no counter means no stats request", async () => {
  let requested = false;
  assert.equal(await refreshDownloadStats({
    root: fakeRoot({ counters: [] }),
    url: "/api/download-stats",
    locale: "en-US",
    fetchImpl: async () => {
      requested = true;
      return okJSON({ total: 25 });
    },
  }), false);
  assert.equal(requested, false);
});

test("click logging is fire-and-forget and cannot interfere with COS navigation", () => {
  const cosURL = "https://quithide-downloads-1313533016.cos.ap-hongkong.myqcloud.com/releases/v0.5.0/QuitHide.dmg";
  const links = [fakeLink(cosURL), fakeLink(cosURL)];
  const calls = [];
  const neverSettles = new Promise(() => {});
  installDirectDownloadLogging({
    root: fakeRoot({ links }),
    url: "/api/download-events",
    fetchImpl: (url, options) => {
      calls.push({ url, options });
      return neverSettles;
    },
  });

  let prevented = false;
  const result = links[0].click({
    preventDefault() { prevented = true; },
  });
  assert.equal(result, undefined);
  assert.equal(prevented, false);
  assert.equal(links[0].href, cosURL);
  assert.deepEqual(calls, [{
    url: "/api/download-events",
    options: {
      method: "POST",
      cache: "no-store",
      credentials: "omit",
      keepalive: true,
    },
  }]);
});

test("logging failures are swallowed synchronously and asynchronously", async () => {
  const asyncLink = fakeLink("https://downloads.example.com/QuitHide.dmg");
  installDirectDownloadLogging({
    root: fakeRoot({ links: [asyncLink] }),
    url: "/api/download-events",
    fetchImpl: () => Promise.reject(new Error("offline")),
  });
  assert.doesNotThrow(() => asyncLink.click());
  await new Promise((resolve) => setImmediate(resolve));

  const syncLink = fakeLink("https://downloads.example.com/QuitHide.dmg");
  installDirectDownloadLogging({
    root: fakeRoot({ links: [syncLink] }),
    url: "/api/download-events",
    fetchImpl: () => { throw new Error("unavailable"); },
  });
  assert.doesNotThrow(() => syncLink.click());
});

function fakeCounter(value) {
  return {
    dataset: { downloadCount: String(value) },
    textContent: new Intl.NumberFormat("en-US").format(value),
  };
}

function fakeLink(href) {
  const listeners = new Map();
  return {
    href,
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    click(event = {}) {
      return listeners.get("click")?.(event);
    },
  };
}

function fakeRoot({ counters = [], links = [] }) {
  return {
    querySelectorAll(selector) {
      if (selector === "[data-download-count]") return counters;
      if (selector === "[data-direct-download]") return links;
      return [];
    },
  };
}

function okJSON(value) {
  return { ok: true, status: 200, json: async () => value };
}
