import { getStore } from "@edgeone/pages-blob";
import {
  createDirectDownloadEventResponse,
  DOWNLOAD_STATS_STORE,
} from "../../lib/download-stats-service.js";

export function onRequestPost({ env, waitUntil }) {
  return createDirectDownloadEventResponse({
    store: getStore(env?.DOWNLOAD_STATS_STORE || DOWNLOAD_STATS_STORE),
    waitUntil,
  });
}
