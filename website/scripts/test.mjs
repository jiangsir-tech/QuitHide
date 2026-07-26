import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import "./build.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const outputDirectory = path.resolve(scriptDirectory, "../dist");
const release = JSON.parse(await readFile(path.join(outputDirectory, "release.json"), "utf8"));
const chinese = await readFile(path.join(outputDirectory, "index.html"), "utf8");
const english = await readFile(path.join(outputDirectory, "en/index.html"), "utf8");

for (const [label, content] of [["Chinese page", chinese], ["English page", english]]) {
  if (content.includes("{{")) throw new Error(`${label} contains unresolved tokens`);
  if (!content.includes(`v${release.version}`)) throw new Error(`${label} has the wrong version`);
  if (!content.includes(release.file.sha256)) throw new Error(`${label} is missing SHA-256`);
  if (!content.includes(release.file.directDownloadURL)) {
    throw new Error(`${label} is missing the direct download URL`);
  }
  if (!content.includes(release.githubReleaseURL)) {
    throw new Error(`${label} is missing the GitHub release URL`);
  }
}

console.log(`PASS: bilingual product site metadata for v${release.version}`);
