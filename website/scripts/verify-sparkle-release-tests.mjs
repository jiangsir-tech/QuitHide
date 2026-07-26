import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { verifySparkleRelease } from "./verify-sparkle-release.mjs";
import { verifyReleaseProgression } from "./verify-release-progression.mjs";

const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "quithide-sparkle-test-"));

try {
  const version = "9.8.7";
  const build = 987;
  const tag = `v${version}`;
  const dmgName = `QuitHide-${tag}-universal.dmg`;
  const checksumName = `${dmgName}.sha256`;
  const appcastName = `QuitHide-${tag}-appcast.xml`;
  const dmgPath = path.join(temporaryDirectory, dmgName);
  const checksumPath = path.join(temporaryDirectory, checksumName);
  const appcastPath = path.join(temporaryDirectory, appcastName);
  const manifestPath = path.join(temporaryDirectory, "update.json");
  const releasePath = path.join(temporaryDirectory, "release.json");
  const publicFeedPath = path.join(temporaryDirectory, "public-release.json");
  const downloadBaseURL = "https://downloads.example.com";
  const dmg = Buffer.from("fixture DMG bytes\n", "utf8");
  const sha256 = createHash("sha256").update(dmg).digest("hex");
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const rawPublicKey = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
  const publicKeyBase64 = rawPublicKey.toString("base64");
  const archiveSignature = sign(null, dmg, privateKey).toString("base64");

  const manifest = {
    version,
    build,
    minimumSystemVersion: "13.0",
    releaseNotes: "测试安全更新发布流程。",
    releaseNotesEn: "Tests the secure update publishing flow.",
    downloadURL: `https://github.com/jiangsir-tech/QuitHide/releases/tag/${tag}`,
  };
  const feedContent = Buffer.from(`<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>Version ${version}</title>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="${downloadBaseURL}/releases/${tag}/${dmgName}" length="${dmg.length}" type="application/octet-stream" sparkle:edSignature="${archiveSignature}" />
    </item>
  </channel>
</rss>
`, "utf8");
  const feedSignature = sign(null, feedContent, privateKey).toString("base64");
  const signedFeed = Buffer.concat([
    feedContent,
    Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${feedSignature}\nlength: ${feedContent.length}\n-->\n`),
  ]);

  await writeFile(dmgPath, dmg);
  await writeFile(checksumPath, `${sha256}  ${dmgName}\n`);
  await writeFile(appcastPath, signedFeed);
  await writeFile(manifestPath, `${JSON.stringify(manifest)}\n`);
  await writeFile(releasePath, `${JSON.stringify({
    tag_name: tag,
    draft: true,
    prerelease: false,
    published_at: null,
    assets: await Promise.all([
      [dmgName, dmgPath],
      [checksumName, checksumPath],
      [appcastName, appcastPath],
    ].map(async ([name, file]) => {
      const data = await import("node:fs/promises").then(({ readFile }) => readFile(file));
      return {
        name,
        size: data.length,
        digest: `sha256:${createHash("sha256").update(data).digest("hex")}`,
      };
    })),
  })}\n`);
  await writeFile(publicFeedPath, `${JSON.stringify({ version: "9.8.6", build: 986 })}\n`);

  await verifySparkleRelease({
    manifest: manifestPath,
    dmg: dmgPath,
    checksum: checksumPath,
    appcast: appcastPath,
    downloadBaseUrl: downloadBaseURL,
    publicKey: publicKeyBase64,
    release: releasePath,
    releaseState: "draft",
  });
  await verifyReleaseProgression({
    manifest: manifestPath,
    publicFeed: publicFeedPath,
    releaseState: "draft",
  });

  await writeFile(publicFeedPath, `${JSON.stringify({ version, build })}\n`);
  await verifyReleaseProgression({
    manifest: manifestPath,
    publicFeed: publicFeedPath,
    releaseState: "published",
  });

  await writeFile(publicFeedPath, `${JSON.stringify({ version: "9.9.0", build: 986 })}\n`);
  await expectFailure(
    () => verifyReleaseProgression({
      manifest: manifestPath,
      publicFeed: publicFeedPath,
      releaseState: "draft",
    }),
    "semantic version rollback",
  );

  await writeFile(publicFeedPath, `${JSON.stringify({ version: "9.8.6", build: 988 })}\n`);
  await expectFailure(
    () => verifyReleaseProgression({
      manifest: manifestPath,
      publicFeed: publicFeedPath,
      releaseState: "draft",
    }),
    "build rollback",
  );

  const wrongURLFeed = Buffer.from(
    signedFeed.toString("utf8").replace(downloadBaseURL, "https://wrong.example.com"),
  );
  await writeFile(appcastPath, wrongURLFeed);
  await expectFailure(
    () => verifySparkleRelease({
      manifest: manifestPath,
      dmg: dmgPath,
      checksum: checksumPath,
      appcast: appcastPath,
      downloadBaseUrl: downloadBaseURL,
      publicKey: publicKeyBase64,
    }),
    "tampered appcast",
  );

  console.log("PASS: signed Sparkle release and monotonic-version guards");
} finally {
  await rm(temporaryDirectory, { recursive: true, force: true });
}

async function expectFailure(operation, label) {
  try {
    await operation();
  } catch {
    return;
  }
  throw new Error(`Expected ${label} verification to fail`);
}
