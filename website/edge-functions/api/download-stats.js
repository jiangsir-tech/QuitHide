import { getStore } from "@edgeone/pages-blob";
import {
  createPublicStatsResponse,
  DOWNLOAD_STATS_STORE,
} from "../../lib/download-stats-service.js";

export function onRequestGet({ env }) {
  return createPublicStatsResponse(getStore(env?.DOWNLOAD_STATS_STORE || DOWNLOAD_STATS_STORE));
}
