import { getStore } from "@edgeone/pages-blob";
import {
  createRefreshResponse,
  DOWNLOAD_STATS_STORE,
} from "../../../lib/download-stats-service.js";

export function onRequestPost({ env }) {
  return createRefreshResponse({
    store: getStore(env?.DOWNLOAD_STATS_STORE || DOWNLOAD_STATS_STORE),
    githubToken: env?.GITHUB_API_TOKEN,
  });
}
