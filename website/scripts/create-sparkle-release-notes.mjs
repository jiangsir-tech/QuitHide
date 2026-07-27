import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderSparkleReleaseNotesHTML } from "../lib/release-history-core.mjs";

const options = parseArguments(process.argv.slice(2));
const historyPath = requiredOption(options, "history");
const manifestPath = requiredOption(options, "manifest");
const outputPath = requiredOption(options, "output");
const history = JSON.parse(await readFile(historyPath, "utf8"));
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const html = renderSparkleReleaseNotesHTML(history, manifest);

await writeFile(outputPath, `${html}\n`);
if (path.resolve(outputPath) !== "/dev/null") {
  console.log(`Generated adaptive Sparkle release notes: ${outputPath}`);
}

function parseArguments(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];
    if (!key?.startsWith("--") || !value) {
      throw new Error(`Invalid argument near ${key}`);
    }
    const camelCase = key.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    result[camelCase] = value;
  }
  return result;
}

function requiredOption(value, name) {
  const result = value[name];
  if (!result) throw new Error(`Missing --${name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`);
  return result;
}

if (!process.argv[1] || fileURLToPath(import.meta.url) !== path.resolve(process.argv[1])) {
  throw new Error("create-sparkle-release-notes.mjs must run as a command");
}
