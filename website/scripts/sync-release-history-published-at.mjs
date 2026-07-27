import { readFile, writeFile } from "node:fs/promises";
import {
  synchronizeReleasePublicationDate,
} from "../lib/release-history-core.mjs";

const options = parseArguments(process.argv.slice(2));
const historyPath = requiredOption(options, "history");
const manifestPath = requiredOption(options, "manifest");
const releasePath = requiredOption(options, "release");
const outputPath = requiredOption(options, "output");
const history = JSON.parse(await readFile(historyPath, "utf8"));
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const release = JSON.parse(await readFile(releasePath, "utf8"));
const expectedTag = `v${manifest.version}`;

if (release.tag_name !== expectedTag || release.draft || release.prerelease) {
  throw new Error(`Expected a published stable GitHub release for ${expectedTag}`);
}
const updatedHistory = synchronizeReleasePublicationDate(
  history,
  manifest,
  release.published_at,
);
await writeFile(outputPath, `${JSON.stringify(updatedHistory, null, 2)}\n`);
console.log(
  `Synchronized ${expectedTag} publication date: ${release.published_at}`,
);

function parseArguments(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];
    if (!key?.startsWith("--") || !value) {
      throw new Error(`Invalid argument near ${key}`);
    }
    const camelCase = key.slice(2).replace(
      /-([a-z])/g,
      (_, letter) => letter.toUpperCase(),
    );
    result[camelCase] = value;
  }
  return result;
}

function requiredOption(value, name) {
  const result = value[name];
  if (!result) {
    const option = name.replace(
      /[A-Z]/g,
      (letter) => `-${letter.toLowerCase()}`,
    );
    throw new Error(`Missing --${option}`);
  }
  return result;
}
