import {
  createHash,
  createPublicKey,
  verify as verifySignature,
} from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  renderSparkleReleaseNotesHTML,
  validateReleaseHistory,
} from "../lib/release-history-core.mjs";

const feedSignaturePrefix = Buffer.from("<!-- sparkle-signatures:\n", "utf8");
const feedSignatureSuffix = Buffer.from("-->", "utf8");
const ed25519SPKIPrefix = Buffer.from("302a300506032b6570032100", "hex");

export async function verifySparkleRelease(options) {
  const manifest = JSON.parse(await readFile(requiredOption(options, "manifest"), "utf8"));
  const dmgPath = requiredOption(options, "dmg");
  const checksumPath = requiredOption(options, "checksum");
  const appcastPath = requiredOption(options, "appcast");
  const downloadBaseURL = normalizedHTTPSBaseURL(
    requiredOption(options, "downloadBaseUrl"),
  );
  const publicKey = decodeBase64(
    requiredOption(options, "publicKey"),
    32,
    "Sparkle public key",
  );

  validateManifest(manifest);
  const tagName = `v${manifest.version}`;
  const dmgName = `QuitHide-${tagName}-universal.dmg`;
  const checksumName = `${dmgName}.sha256`;
  const appcastName = `QuitHide-${tagName}-appcast.xml`;
  if (path.basename(dmgPath) !== dmgName) {
    throw new Error(`Unexpected DMG name; expected ${dmgName}`);
  }
  if (path.basename(checksumPath) !== checksumName) {
    throw new Error(`Unexpected checksum name; expected ${checksumName}`);
  }
  if (path.basename(appcastPath) !== appcastName) {
    throw new Error(`Unexpected appcast name; expected ${appcastName}`);
  }

  const dmg = await readFile(dmgPath);
  const checksum = await readFile(checksumPath, "utf8");
  const checksumMatch = checksum.match(/^([a-fA-F0-9]{64})[\t ]+\*?([^\r\n]+)\r?\n?$/);
  if (!checksumMatch) throw new Error("Invalid SHA-256 file");
  if (path.basename(checksumMatch[2].trim()) !== dmgName) {
    throw new Error("SHA-256 file refers to a different artifact");
  }
  const expectedSHA256 = checksumMatch[1].toLowerCase();
  const actualSHA256 = createHash("sha256").update(dmg).digest("hex");
  if (actualSHA256 !== expectedSHA256) throw new Error("DMG SHA-256 mismatch");

  const expectedDownloadURL = `${downloadBaseURL}/releases/${tagName}/${dmgName}`;
  const appcast = await readFile(appcastPath);
  const signedFeed = extractSignedFeed(appcast);
  verifyEd25519(
    signedFeed.content,
    signedFeed.signature,
    publicKey,
    "appcast feed",
  );

  const appcastXML = signedFeed.content.toString("utf8");
  const item = currentItem(appcastXML, manifest);
  if (options.releaseHistory) {
    const history = JSON.parse(await readFile(options.releaseHistory, "utf8"));
    const releases = validateReleaseHistory(history, { manifest });
    verifyAdaptiveReleaseNotes(item, history, manifest);
    verifyPreviousReleaseIsRetained(appcastXML, releases);
  }
  const enclosure = enclosureAttributes(item);
  if (enclosure.url !== expectedDownloadURL) {
    throw new Error(`Unexpected appcast download URL: ${enclosure.url}`);
  }
  if (enclosure.type !== "application/octet-stream") {
    throw new Error(`Unexpected appcast enclosure type: ${enclosure.type}`);
  }
  if (Number(enclosure.length) !== dmg.length) {
    throw new Error("Appcast enclosure length does not match the DMG");
  }
  const archiveSignature = decodeBase64(
    enclosure["sparkle:edSignature"],
    64,
    "DMG Ed25519 signature",
  );
  verifyEd25519(dmg, archiveSignature, publicKey, "DMG");
  if (/<sparkle:deltas\b/.test(item)) {
    throw new Error("The current appcast item must not contain delta updates");
  }

  if (options.release) {
    await verifyReleaseAPI({
      releasePath: options.release,
      releaseState: options.releaseState || "either",
      manifest,
      expectedAssets: new Map([
        [dmgName, { path: dmgPath, size: dmg.length }],
        [checksumName, { path: checksumPath }],
        [appcastName, { path: appcastPath }],
      ]),
    });
  }

  return {
    version: manifest.version,
    build: manifest.build,
    tagName,
    dmgName,
    checksumName,
    appcastName,
    sha256: actualSHA256,
    size: dmg.length,
    directDownloadURL: expectedDownloadURL,
  };
}

async function verifyReleaseAPI({
  releasePath,
  releaseState,
  manifest,
  expectedAssets,
}) {
  if (!new Set(["draft", "published", "either"]).has(releaseState)) {
    throw new Error(`Invalid release state: ${releaseState}`);
  }
  const release = JSON.parse(await readFile(releasePath, "utf8"));
  const expectedTag = `v${manifest.version}`;
  if (release.tag_name !== expectedTag) throw new Error("GitHub release tag mismatch");
  if (release.prerelease) throw new Error("Prereleases cannot be published to the stable feed");
  if (releaseState === "draft" && !release.draft) throw new Error("Expected a draft release");
  if (releaseState === "published" && release.draft) {
    throw new Error("Expected a published release");
  }
  if (releaseState === "published" && !release.published_at) {
    throw new Error("Published GitHub release has no publication date");
  }

  const assets = release.assets || [];
  if (assets.length !== expectedAssets.size) {
    throw new Error(`Expected exactly ${expectedAssets.size} GitHub release assets`);
  }
  for (const [name, expected] of expectedAssets) {
    const matches = assets.filter((asset) => asset.name === name);
    if (matches.length !== 1) throw new Error(`GitHub release must contain exactly one ${name}`);
    const asset = matches[0];
    const details = await stat(expected.path);
    const contents = await readFile(expected.path);
    const digest = createHash("sha256").update(contents).digest("hex");
    if (asset.size !== details.size) throw new Error(`GitHub asset size mismatch for ${name}`);
    if (asset.digest && asset.digest !== `sha256:${digest}`) {
      throw new Error(`GitHub asset digest mismatch for ${name}`);
    }
  }
}

function validateManifest(manifest) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(manifest?.version)) {
    throw new Error("Invalid stable version in update manifest");
  }
  if (!Number.isInteger(manifest?.build) || manifest.build <= 0) {
    throw new Error("Invalid build in update manifest");
  }
  if (!/^\d+\.\d+(?:\.\d+)?$/.test(manifest?.minimumSystemVersion)) {
    throw new Error("Invalid minimum system version in update manifest");
  }
  if (!manifest?.releaseNotes?.trim() || !manifest?.releaseNotesEn?.trim()) {
    throw new Error("Bilingual release notes are required");
  }
  const expectedPage = `https://github.com/jiangsir-tech/QuitHide/releases/tag/v${manifest.version}`;
  if (manifest.downloadURL !== expectedPage) {
    throw new Error(`Unexpected legacy download URL: ${manifest.downloadURL}`);
  }
}

function extractSignedFeed(appcast) {
  const prefixIndex = appcast.lastIndexOf(feedSignaturePrefix);
  if (prefixIndex < 0) throw new Error("Appcast feed is not signed");
  const suffixIndex = appcast.indexOf(
    feedSignatureSuffix,
    prefixIndex + feedSignaturePrefix.length,
  );
  if (suffixIndex < 0) throw new Error("Appcast signature block is incomplete");
  const trailing = appcast.subarray(suffixIndex + feedSignatureSuffix.length).toString("utf8");
  if (trailing.trim()) throw new Error("Unexpected data after appcast signature block");

  const content = appcast.subarray(0, prefixIndex);
  const block = appcast
    .subarray(prefixIndex + feedSignaturePrefix.length, suffixIndex)
    .toString("utf8");
  const signatureMatch = block.match(/^edSignature:[\t ]*([^\r\n]+)$/m);
  const lengthMatch = block.match(/^length:[\t ]*(\d+)$/m);
  if (!signatureMatch || !lengthMatch) throw new Error("Invalid appcast signature block");
  if (Number(lengthMatch[1]) !== content.length) {
    throw new Error("Signed appcast content length mismatch");
  }
  return {
    content,
    signature: decodeBase64(signatureMatch[1].trim(), 64, "appcast Ed25519 signature"),
  };
}

function currentItem(xml, manifest) {
  const items = appcastItems(xml);
  const matches = items.filter((item) => (
    tagValue(item, "sparkle:version") === String(manifest.build)
    && tagValue(item, "sparkle:shortVersionString") === manifest.version
  ));
  if (matches.length !== 1) {
    throw new Error("Signed appcast must contain exactly one item for the current build");
  }
  const minimumSystemVersion = tagValue(matches[0], "sparkle:minimumSystemVersion");
  if (minimumSystemVersion !== manifest.minimumSystemVersion) {
    throw new Error("Appcast minimum system version mismatch");
  }
  return matches[0];
}

function appcastItems(xml) {
  return xml.match(/<item\b[\s\S]*?<\/item>/g) || [];
}

function verifyAdaptiveReleaseNotes(item, history, manifest) {
  const match = item.match(/<description\b([^>]*)>([\s\S]*?)<\/description>/);
  if (!match) throw new Error("Current appcast item has no embedded release notes");
  const attributes = elementAttributes(match[1]);
  if (attributes["sparkle:format"] && attributes["sparkle:format"] !== "html") {
    throw new Error("Adaptive Sparkle release notes must use HTML");
  }
  let contents = match[2].trim();
  if (contents.startsWith("<![CDATA[") && contents.endsWith("]]>")) {
    contents = contents.slice("<![CDATA[".length, -"]]>".length);
  }
  const expected = renderSparkleReleaseNotesHTML(history, manifest);
  if (contents.trim() !== expected.trim()) {
    throw new Error("Current appcast item does not contain the verified cumulative release notes");
  }
}

function verifyPreviousReleaseIsRetained(xml, releases) {
  if (releases.length < 2) return;
  const expectedBuild = String(releases.at(-2).build);
  const matches = appcastItems(xml).filter(
    (item) => tagValue(item, "sparkle:version") === expectedBuild,
  );
  if (matches.length !== 1) {
    throw new Error(`Signed appcast must retain previous build ${expectedBuild}`);
  }
}

function tagValue(xml, name) {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = xml.match(new RegExp(`<${escapedName}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${escapedName}>`));
  return match ? decodeXML(match[1].trim()) : null;
}

function enclosureAttributes(item) {
  const match = item.match(/<enclosure\b([^>]*)\/?\s*>/);
  if (!match) throw new Error("Current appcast item has no enclosure");
  const attributes = elementAttributes(match[1]);
  for (const name of ["url", "length", "type", "sparkle:edSignature"]) {
    if (!attributes[name]) throw new Error(`Appcast enclosure is missing ${name}`);
  }
  return attributes;
}

function elementAttributes(value) {
  const attributes = {};
  const pattern = /([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
  for (const attribute of value.matchAll(pattern)) {
    attributes[attribute[1]] = decodeXML(attribute[2] ?? attribute[3]);
  }
  return attributes;
}

function verifyEd25519(data, signature, rawPublicKey, label) {
  const key = createPublicKey({
    key: Buffer.concat([ed25519SPKIPrefix, rawPublicKey]),
    format: "der",
    type: "spki",
  });
  if (!verifySignature(null, data, key, signature)) {
    throw new Error(`${label} Ed25519 signature is invalid`);
  }
}

function decodeBase64(value, expectedLength, label) {
  if (typeof value !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw new Error(`Invalid ${label}`);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.length !== expectedLength || decoded.toString("base64") !== value) {
    throw new Error(`Invalid ${label}`);
  }
  return decoded;
}

function decodeXML(value) {
  return value
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

function normalizedHTTPSBaseURL(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new Error("Download base URL must be a plain HTTPS URL");
  }
  return url.toString().replace(/\/$/, "");
}

function requiredOption(options, name) {
  const value = options[name];
  if (!value) throw new Error(`Missing --${toKebabCase(name)}`);
  return value;
}

function toKebabCase(value) {
  return value.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

function parseArguments(values) {
  const options = {};
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];
    if (!key?.startsWith("--") || !value) throw new Error(`Invalid argument near ${key}`);
    const camelCase = key.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    options[camelCase] = value;
  }
  return options;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const result = await verifySparkleRelease(parseArguments(process.argv.slice(2)));
  console.log(JSON.stringify(result));
}
