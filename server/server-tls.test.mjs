import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import https from "node:https";
import net from "node:net";
import { spawn, execFileSync } from "node:child_process";

function opensslAvailable() {
  try {
    execFileSync("openssl", ["version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

async function freePort() {
  const probe = net.createServer();
  await new Promise((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const port = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

function readHttps(url, ca) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { ca }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks)) }));
    });
    request.on("error", reject);
  });
}

test("server starts HTTPS with configured certificate and reports secure transport", {
  skip: !opensslAvailable()
}, async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tls-"));
  const cert = path.join(root, "cert.pem");
  const key = path.join(root, "key.pem");
  execFileSync("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", key, "-out", cert, "-days", "1",
    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"
  ], { stdio: "ignore" });
  const port = await freePort();
  const server = spawn(process.execPath, ["server/index.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      CODMES_HOST: "127.0.0.1",
      CODMES_PORT: String(port),
      CODMES_WORKSPACE_ROOT: path.join(root, "workspace"),
      CODMES_TLS_CERT: cert,
      CODMES_TLS_KEY: key,
      CODMES_MULTIUSER_ENABLED: "false"
    },
    stdio: "ignore"
  });
  try {
    const ca = await fs.readFile(cert);
    const deadline = Date.now() + 10_000;
    let result;
    while (Date.now() < deadline) {
      try {
        result = await readHttps(`https://127.0.0.1:${port}/api/health`, ca);
        break;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }
    assert.equal(result?.status, 200);
    assert.equal(result.body.secureTransport, true);
  } finally {
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await fs.rm(root, { recursive: true, force: true });
  }
});
