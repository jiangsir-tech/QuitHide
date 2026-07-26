import { createHash } from "node:crypto";
import { readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";

const argumentsMap = parseArguments(process.argv.slice(2));
const releaseAPI = JSON.parse(await readFile(required("release"), "utf8"));
const manifest = JSON.parse(await readFile(required("manifest"), "utf8"));
const dmgPath = required("dmg");
const checksumPath = required("checksum");
const outputPath = required("output");

const version = manifest.version;
const tagName = `v${version}`;
if (releaseAPI.tag_name !== tagName) {
  throw new Error(`Release tag ${releaseAPI.tag_name} does not match manifest ${tagName}`);
}
if (releaseAPI.draft || releaseAPI.prerelease) {
  throw new Error("The website feed accepts stable published releases only");
}
if (!manifest.releaseNotes?.trim() || !manifest.releaseNotesEn?.trim()) {
  throw new Error("The update manifest requires Chinese and English release notes");
}

const dmgName = path.basename(dmgPath);
const expectedName = `QuitHide-v${version}-universal.dmg`;
if (dmgName !== expectedName) {
  throw new Error(`Unexpected DMG name ${dmgName}; expected ${expectedName}`);
}

const checksumText = await readFile(checksumPath, "utf8");
const checksumMatch = checksumText.match(/^([a-fA-F0-9]{64})\s+/);
if (!checksumMatch) throw new Error("Invalid SHA-256 file");
const expectedSHA256 = checksumMatch[1].toLowerCase();
const actualSHA256 = createHash("sha256").update(await readFile(dmgPath)).digest("hex");
if (actualSHA256 !== expectedSHA256) throw new Error("DMG SHA-256 mismatch");

const fileDetails = await stat(dmgPath);
const releaseAsset = releaseAPI.assets?.find((asset) => asset.name === dmgName);
if (!releaseAsset) throw new Error(`GitHub release is missing ${dmgName}`);
if (releaseAsset.size !== fileDetails.size) throw new Error("GitHub asset size mismatch");
if (releaseAsset.digest && releaseAsset.digest !== `sha256:${actualSHA256}`) {
  throw new Error("GitHub asset digest mismatch");
}

const baseURL = process.env.QUITHIDE_DOWNLOAD_BASE_URL?.replace(/\/$/, "");
if (baseURL && new URL(baseURL).protocol !== "https:") {
  throw new Error("QUITHIDE_DOWNLOAD_BASE_URL must use HTTPS");
}
const directDownloadURL = baseURL
  ? `${baseURL}/releases/${tagName}/${dmgName}`
  : releaseAsset.browser_download_url;

const feed = {
  version,
  build: manifest.build,
  minimumSystemVersion: manifest.minimumSystemVersion,
  publishedAt: releaseAPI.published_at,
  releaseNotes: {
    "zh-CN": manifest.releaseNotes,
    en: manifest.releaseNotesEn,
  },
  githubReleaseURL: releaseAPI.html_url,
  file: {
    name: dmgName,
    size: fileDetails.size,
    sha256: actualSHA256,
    directDownloadURL,
    githubDownloadURL: releaseAsset.browser_download_url,
  },
};

await writeFile(outputPath, `${JSON.stringify(feed, null, 2)}\n`);
console.log(`Generated release feed for ${tagName}: ${directDownloadURL}`);

function parseArguments(values) {
  const result = new Map();
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];
    if (!key?.startsWith("--") || !value) throw new Error(`Invalid argument near ${key}`);
    result.set(key.slice(2), value);
  }
  return result;
}

function required(name) {
  const value = argumentsMap.get(name);
  if (!value) throw new Error(`Missing --${name}`);
  return value;
}
