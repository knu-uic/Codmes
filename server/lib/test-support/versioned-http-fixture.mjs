// Disposable localhost-only server for native client interoperability tests.
// Never reads the installed Codmes workspace, configuration or credentials.
import http from "node:http";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { stageSyncUpload, discardStagedSyncUpload, applySyncChange, applySyncMove, stageSyncBundle, applySyncBundle, discardSyncBundle, syncDevicePolicies, syncManifest, readSyncBlob, syncHistory, readHistoricalSyncBlob, withWorkspaceFileLock } from "../workspace-sync.mjs";

const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-native-wire-"));
const roots = new Map();
const drops = new Set();
const server = http.createServer(async (req, res) => {
  try {
    const auth = req.headers.authorization;
    if (!/^Bearer test-profile-[ab]$/.test(auth ?? "")) { res.writeHead(401); return res.end("test profile required"); }
    if (!roots.has(auth)) {
      const workspace = path.join(root, auth.endsWith("a") ? "a" : "b");
      await fs.mkdir(path.join(workspace, "Notes"), { recursive: true }); await fs.mkdir(path.join(workspace, "Code"), { recursive: true }); roots.set(auth, workspace);
    }
    const workspace = roots.get(auth);
    const url = new URL(req.url, "http://127.0.0.1");
    let result;
    const logicalPath = url.searchParams.get("path"), resource = url.searchParams.get("resource") || "file";
    if (req.method === "POST" && url.pathname === "/fixture/drop-next") { drops.add(auth); result = { ok: true }; }
    else if (req.method === "GET" && url.pathname === "/api/sync/manifest") result = await withWorkspaceFileLock(workspace, () => syncManifest(workspace));
    else if (req.method === "POST" && ["/api/sync/devices", "/api/sync/move"].includes(url.pathname)) {
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      result = await withWorkspaceFileLock(workspace, () => url.pathname.endsWith("devices") ? syncDevicePolicies(workspace, body.deviceId, body.policies) : applySyncMove(workspace, body));
    }
    else if (req.method === "GET" && url.pathname === "/api/sync/blob") {
      const data = await withWorkspaceFileLock(workspace, () => readSyncBlob(workspace, logicalPath, resource, url.searchParams.get("revision")));
      res.writeHead(200, { "Content-Type": "application/octet-stream" }); return res.end(data);
    } else if (req.method === "GET" && url.pathname === "/api/sync/history") result = await withWorkspaceFileLock(workspace, () => syncHistory(workspace, logicalPath, resource));
    else if (req.method === "GET" && url.pathname === "/api/sync/history/blob") {
      const data = await withWorkspaceFileLock(workspace, () => readHistoricalSyncBlob(workspace, logicalPath, resource, url.searchParams.get("version")));
      res.writeHead(200, { "Content-Type": "application/octet-stream" }); return res.end(data);
    } else if (req.method === "PUT" && url.pathname === "/api/sync/document") {
      const bundle = await stageSyncBundle(workspace, req);
      try { result = await withWorkspaceFileLock(workspace, () => applySyncBundle(workspace, bundle)); }
      finally { await discardSyncBundle(bundle); }
    } else if (req.method === "PUT" && url.pathname === "/api/sync/blob") {
      const staged = await stageSyncUpload(workspace, req);
      try {
        const headers = req.headers;
        const change = { path: logicalPath, resource, baseRevision: headers["x-codmes-base-revision"] === "missing" ? null : headers["x-codmes-base-revision"], conflictPolicy: headers["x-codmes-conflict-policy"], operationId: headers["x-codmes-operation-id"], deviceId: headers["x-codmes-device-id"], modifiedAt: headers["x-codmes-modified-at"], baseVersion: headers["x-codmes-base-version"] ?? null };
        change.fileId = headers["x-codmes-file-id"]; change.firstRegistration = headers["x-codmes-first-registration"] === "true"; change.expectedRevision = headers["x-codmes-expected-revision"];
        result = await withWorkspaceFileLock(workspace, () => applySyncChange(workspace, change, staged));
        if (drops.delete(auth)) { res.destroy(); return; }
      } finally { await discardStagedSyncUpload(staged); }
    } else if (req.method === "POST" && url.pathname === "/fixture/stop") { res.end("stopping"); await close(); return; }
    else { res.writeHead(404); return res.end("not found"); }
    res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(result));
  } catch (error) { res.writeHead(error.status ?? 500, { "Content-Type": "application/json" }); res.end(JSON.stringify({ error: error.message })); }
});
let closing = false;
async function close() {
  if (closing) return; closing = true;
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  await fs.rm(root, { recursive: true, force: true });
}
process.on("SIGTERM", () => close().then(() => process.exit(0)));
process.on("SIGINT", () => close().then(() => process.exit(0)));
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
process.stdout.write(JSON.stringify({ url: `http://127.0.0.1:${server.address().port}` }) + "\n");
