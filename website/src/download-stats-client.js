export async function refreshDownloadStats({
  root,
  url,
  locale,
  fetchImpl = fetch,
}) {
  const counters = [...root.querySelectorAll("[data-download-count]")];
  if (counters.length === 0) return false;

  const currentValues = counters.map((counter) => {
    const value = Number(counter.dataset.downloadCount);
    return Number.isSafeInteger(value) && value >= 0 ? value : null;
  }).filter((value) => value !== null);
  if (currentValues.length === 0) return false;
  const current = Math.max(...currentValues);
  const response = await fetchImpl(url, {
    cache: "no-store",
    credentials: "omit",
    headers: { Accept: "application/json" },
  });
  if (!response.ok) throw new Error(`Download stats returned ${response.status}`);
  const stats = await response.json();
  if (!Number.isSafeInteger(stats?.total) || stats.total < current) return false;

  const formatted = new Intl.NumberFormat(locale).format(stats.total);
  counters.forEach((counter) => {
    counter.dataset.downloadCount = String(stats.total);
    counter.textContent = formatted;
  });
  return true;
}

export function installDirectDownloadLogging({ root, url, fetchImpl = fetch }) {
  root.querySelectorAll("[data-direct-download]").forEach((link) => {
    link.addEventListener("click", () => {
      try {
        const request = fetchImpl(url, {
          method: "POST",
          cache: "no-store",
          credentials: "omit",
          keepalive: true,
        });
        Promise.resolve(request).catch(() => {});
      } catch {
        // Counting is best effort; the link's normal navigation is untouched.
      }
    });
  });
}
