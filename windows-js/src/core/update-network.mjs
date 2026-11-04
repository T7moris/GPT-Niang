import fs from "node:fs";
import path from "node:path";
import https from "node:https";
import { createHash } from "node:crypto";

export const DAY = 86400000;
export const RELEASE_API =
  "https://api.github.com/repos/T7moris/GPT-Niang/releases/latest";
const RELEASE_PATH = "/T7moris/GPT-Niang/releases/download/";
const MAX_ZIP = 1024 * 1024 * 1024;
const read = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};
export function versionParts(version) {
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(version);
  return match ? match.slice(1).map(BigInt) : null;
}
function packageVersion(version) {
  const match=/^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.exec(version);
  if(!match)return null;
  const prerelease=match[4]?.split('.')??[];
  if(prerelease.some(part=>/^\d+$/.test(part)&&part.length>1&&part.startsWith('0')))return null;
  return {core:match.slice(1,4).map(BigInt),prerelease};
}
export function compareVersions(a, b) {
  const left = packageVersion(a),right = packageVersion(b);
  if (!left || !right) throw new Error("Invalid version");
  for (let i = 0; i < 3; i++)
    if (left.core[i] !== right.core[i]) return left.core[i] > right.core[i] ? 1 : -1;
  if(!left.prerelease.length||!right.prerelease.length)
    return left.prerelease.length===right.prerelease.length?0:left.prerelease.length?-1:1;
  for(let i=0;i<Math.max(left.prerelease.length,right.prerelease.length);i++){
    const l=left.prerelease[i],r=right.prerelease[i];
    if(l===r)continue;if(l===undefined)return -1;if(r===undefined)return 1;
    const ln=/^\d+$/.test(l),rn=/^\d+$/.test(r);
    if(ln&&rn)return BigInt(l)>BigInt(r)?1:-1;
    if(ln!==rn)return ln?-1:1;
    return l>r?1:-1;
  }
  return 0;
}
export function updatePreferences(dataDir) {
  return {
    automatic:
      read(path.join(dataDir, "update-preferences.json"))?.automatic !== false,
  };
}
export function checkDue(state, startedAt, now = Date.now()) {
  return now >= Math.max(startedAt + 30000, Number(state?.nextCheckAt) || 0);
}
export function isGitCheckout(directory) {
  for (let dir = path.resolve(directory); ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, ".git"))) return true;
    if (path.dirname(dir) === dir) return false;
  }
}
export function allowedUrl(value, { api = false } = {}) {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.port ||
    url.hash
  )
    throw new Error("Untrusted update URL");
  const host = url.hostname.toLowerCase();
  const allowed = api
    ? value === RELEASE_API
    : (host === "github.com" && url.pathname.startsWith(RELEASE_PATH)) ||
      [
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
      ].includes(host);
  if (!allowed) throw new Error("Untrusted update host");
  return url;
}

// No token, cookie, proxy credentials or login configuration is read here.
export async function download(
  url,
  {
    limit = MAX_ZIP,
    api = false,
    request = https.get,
    onProgress = () => {},
    redirects = 0,
  } = {},
) {
  allowedUrl(url, { api });
  if (redirects > 5) throw new Error("Too many update redirects");
  return new Promise((resolve, reject) => {
    const req = request(
      url,
      {
        headers: {
          "User-Agent": "GPTNiangUsage-Updater",
          Accept: api
            ? "application/vnd.github+json"
            : "application/octet-stream",
        },
      },
      (response) => {
        const status = response.statusCode;
        if ([301, 302, 303, 307, 308].includes(status)) {
          response.resume();
          if (api) {
            reject(new Error("Unexpected API redirect"));
            return;
          }
          try {
            const next = new URL(response.headers.location, url).href;
            download(next, {
              limit,
              request,
              onProgress,
              redirects: redirects + 1,
            }).then(resolve, reject);
          } catch (error) {
            reject(error);
          }
          return;
        }
        if (status !== 200) {
          response.resume();
          const error = new Error(
            "GitHub update request failed (" + status + ")",
          );
          if (
            status === 429 ||
            (status === 403 &&
              response.headers["x-ratelimit-remaining"] === "0")
          ) {
            const retry = response.headers["retry-after"];
            const seconds = /^\d+$/.test(retry ?? "")
              ? Number(retry) * 1000
              : Date.parse(retry) - Date.now();
            const reset =
              Number(response.headers["x-ratelimit-reset"]) * 1000 - Date.now();
            const hints = [seconds, reset].filter(
              (value) => Number.isFinite(value) && value >= 0,
            );
            error.retryAfterMs = hints.length ? Math.max(1000, ...hints) : DAY;
          }
          reject(error);
          return;
        }
        if (Number(response.headers["content-length"]) > limit) {
          response.destroy();
          reject(new Error("Update download exceeds size limit"));
          return;
        }
        const chunks = [];
        let bytes = 0;
        response.on("data", (chunk) => {
          bytes += chunk.length;
          if (bytes > limit) {
            response.destroy(new Error("Update download exceeds size limit"));
            return;
          }
          chunks.push(chunk);
          try {
            onProgress(bytes);
          } catch (error) {
            response.destroy(error);
          }
        });
        response.on("error", reject);
        response.on("aborted", () =>
          reject(new Error("Update download interrupted")),
        );
        response.on("end", () => resolve(Buffer.concat(chunks)));
      },
    );
    req.on("error", reject);
    req.setTimeout(30000, () =>
      req.destroy(new Error("Update download timed out")),
    );
  });
}
export function selectRelease(release, currentVersion) {
  if (release.draft || release.prerelease || !versionParts(release.tag_name))
    return null;
  if (compareVersions(release.tag_name, currentVersion) <= 0) return null;
  const version = release.tag_name.replace(/^v/, "");
  const name = `gpt-niang-usage-widget-v${version}-windows-js.zip`;
  const choose = (name) => {
    const matches = (release.assets ?? []).filter(
      (asset) => asset.name === name,
    );
    if (matches.length !== 1)
      throw new Error("Required Windows release asset missing or duplicated");
    const asset = matches[0];
    allowedUrl(asset.browser_download_url);
    const expected =
      RELEASE_PATH +
      encodeURIComponent(release.tag_name) +
      "/" +
      encodeURIComponent(name);
    if (
      new URL(asset.browser_download_url).hostname !== "github.com" ||
      new URL(asset.browser_download_url).pathname !== expected
    )
      throw new Error("Release asset path mismatch");
    if (asset.size > MAX_ZIP)
      throw new Error("Release asset exceeds size limit");
    return asset;
  };
  return { version, zip: choose(name), sums: choose("SHA256SUMS.txt") };
}
export function verifyHash(bytes, sums, asset) {
  const matching = sums
    .toString("utf8")
    .split(/\r?\n/)
    .filter((line) => line.slice(66).replace(/^\*/, "") === asset.name);
  if (matching.length !== 1 || !/^[a-f\d]{64} [ *]/i.test(matching[0]))
    throw new Error("Invalid release checksum file");
  const hash = createHash("sha256").update(bytes).digest("hex");
  if (hash !== matching[0].slice(0, 64).toLowerCase())
    throw new Error("Release SHA256 mismatch");
  verifyAssetDigest(bytes, asset);
  return hash;
}
export function verifyAssetDigest(bytes, asset) {
  if (
    asset.digest &&
    asset.digest.toLowerCase() !==
      "sha256:" + createHash("sha256").update(bytes).digest("hex")
  )
    throw new Error("GitHub asset digest mismatch");
  if (Number.isSafeInteger(asset.size) && asset.size !== bytes.length)
    throw new Error("GitHub asset size mismatch");
}
