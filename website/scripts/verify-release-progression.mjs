import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export async function verifyReleaseProgression(options) {
  const manifest = JSON.parse(await readFile(requiredOption(options, "manifest"), "utf8"));
  const publicFeed = JSON.parse(await readFile(requiredOption(options, "publicFeed"), "utf8"));
  const releaseState = requiredOption(options, "releaseState");

  if (!new Set(["draft", "published"]).has(releaseState)) {
    throw new Error(`Invalid release state: ${releaseState}`);
  }
  validateVersionedBuild(manifest, "release manifest");
  validateVersionedBuild(publicFeed, "public release feed");

  const versionComparison = compareSemanticVersions(manifest.version, publicFeed.version);
  const buildComparison = Math.sign(manifest.build - publicFeed.build);

  if (releaseState === "draft") {
    if (versionComparison <= 0 || buildComparison <= 0) {
      throw new Error(
        `Draft ${manifest.version} (${manifest.build}) must be newer than `
        + `public ${publicFeed.version} (${publicFeed.build})`,
      );
    }
    return { mode: "new", version: manifest.version, build: manifest.build };
  }

  if (versionComparison < 0 || buildComparison < 0) {
    throw new Error(
      `Published ${manifest.version} (${manifest.build}) cannot replace newer `
      + `public ${publicFeed.version} (${publicFeed.build})`,
    );
  }
  if ((versionComparison === 0) !== (buildComparison === 0)) {
    throw new Error("A retry must match both the public version and build");
  }

  return {
    mode: versionComparison === 0 ? "retry" : "new",
    version: manifest.version,
    build: manifest.build,
  };
}

function compareSemanticVersions(left, right) {
  const leftComponents = left.split(".").map(Number);
  const rightComponents = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftComponents[index] !== rightComponents[index]) {
      return Math.sign(leftComponents[index] - rightComponents[index]);
    }
  }
  return 0;
}

function validateVersionedBuild(value, label) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value?.version)) {
    throw new Error(`Invalid version in ${label}`);
  }
  if (!Number.isInteger(value?.build) || value.build <= 0) {
    throw new Error(`Invalid build in ${label}`);
  }
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
  const result = await verifyReleaseProgression(parseArguments(process.argv.slice(2)));
  console.log(JSON.stringify(result));
}
