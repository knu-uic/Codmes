import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import http from "node:http";
import { annotationsPathForDocument, documentManifestPath, documentStateDirectory } from "./lib/document-ingest.mjs";

test("workspace server protects APIs with CODMES_SERVER_TOKEN and exposes management APIs", async () => {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-server-api-"));
  const port = 18000 + Math.floor(Math.random() * 10000);
  const token = "test-token";
  const server = spawn(process.execPath, ["server/index.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      NODE_ENV: "test",
      CODMES_HOST: "127.0.0.1",
      CODMES_PORT: String(port),
      CODMES_WORKSPACE_ROOT: workspaceRoot,
      CODMES_SERVER_TOKEN: token
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  try {
    const baseUrl = `http://127.0.0.1:${port}`;
    await waitForServer(`${baseUrl}/api/health`);

    const health = await fetchJson(`${baseUrl}/api/health`);
    assert.equal(health.ok, true);
    assert.equal(health.authRequired, true);

    const unauthorized = await fetch(`${baseUrl}/api/workspace`);
    assert.equal(unauthorized.status, 401);

    const workspace = await fetchJson(`${baseUrl}/api/workspace`, { token });
    assert.equal(workspace.runtime.owner, "codmes");

    const marketplace = await fetchJson(`${baseUrl}/api/marketplace/plugins`, { token });
    assert.equal(
      marketplace.plugins.some((plugin) => plugin.id === "com.codmes.planner"),
      false
    );
    const knuMarketplacePlugin = marketplace.plugins.find((plugin) => plugin.id === "kr.ac.kongju.knu");
    assert.match(knuMarketplacePlugin.version, /^\d+\.\d+\.\d+$/);
    assert.equal(knuMarketplacePlugin.installed, false);

    const installedMarketplacePlugin = await fetchJson(
      `${baseUrl}/api/marketplace/plugins/kr.ac.kongju.knu/install`,
      { token, method: "POST", body: { version: knuMarketplacePlugin.version } }
    );
    assert.equal(installedMarketplacePlugin.plugin.id, "kr.ac.kongju.knu");
    const installedPlugins = await fetchJson(`${baseUrl}/api/plugins`, { token });
    assert.equal(installedPlugins.plugins.some((plugin) => plugin.id === "kr.ac.kongju.knu"), true);
    const emptyToolConsent = await fetchJson(
      `${baseUrl}/api/plugins/kr.ac.kongju.knu/mcp-tools`,
      { token }
    );
    assert.equal(emptyToolConsent.pluginId, "kr.ac.kongju.knu");
    assert.deepEqual(emptyToolConsent.approvedTools, []);
    assert.deepEqual(emptyToolConsent.pendingTools, []);
    const removedMarketplacePlugin = await fetchJson(
      `${baseUrl}/api/plugins/kr.ac.kongju.knu`,
      { token, method: "DELETE" }
    );
    assert.equal(removedMarketplacePlugin.removed, true);

    const builtInPlugins = await fetchJson(`${baseUrl}/api/plugins`, { token });
    const builtInPlanner = builtInPlugins.plugins.find(
      (plugin) => plugin.id === "com.codmes.planner"
    );
    assert.equal(builtInPlanner.distribution, "builtin");
    assert.equal(builtInPlanner.removable, false);
    assert.equal(builtInPlanner.views[0].id, "planner");
    const legacySurfaces = await fetch(`${baseUrl}/api/surfaces`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    assert.equal(legacySurfaces.status, 404);
    const disabledPlanner = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/configuration`,
      { token, method: "POST", body: { enabled: false } }
    );
    assert.equal(disabledPlanner.enabled, false);
    await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/configuration`,
      { token, method: "POST", body: { enabled: true } }
    );
    const plannerSurface = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/view-document?route=tasks`,
      { token }
    );
    assert.equal(plannerSurface.schemaVersion, 2);
    assert.equal(plannerSurface.presentation, "collection");
    assert.equal(plannerSurface.editor.collection, "tasks");
    const createdTask = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/collections/tasks`,
      {
        token,
        method: "POST",
        body: {
          item: {
            title: "Ship Planner",
            dueAt: "2026-07-30T09:00:00+09:00",
            completed: false,
            priority: 1,
            project: "Codmes",
            notes: "Built-in Planner"
          }
        }
      }
    );
    assert.equal(createdTask.created, true);
    const populatedPlannerSurface = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/view-document?route=tasks`,
      { token }
    );
    assert.equal(populatedPlannerSurface.items[0].title, "Ship Planner");
    assert.equal(populatedPlannerSurface.items[0].editorValues.completed, false);
    const calendarCollection = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/collections/events`,
      { token }
    );
    assert.deepEqual(calendarCollection.items, []);
    const calendarSurface = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/view-document?route=events`,
      { token }
    );
    assert.equal(calendarSurface.schemaVersion, 2);
    assert.equal(calendarSurface.presentation, "calendar");
    assert.equal(calendarSurface.editor.fields[0].role, "title");
    assert.equal(calendarSurface.title, "Calendar");
    assert.deepEqual(calendarSurface.items, []);
    const createdCalendarEvent = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/collections/events`,
      {
        token,
        method: "POST",
        body: {
          item: {
            title: "Design review",
            startsAt: "2026-07-29T09:00:00+09:00",
            endsAt: "2026-07-29T10:00:00+09:00",
            allDay: false,
            location: "Studio",
            notes: ""
          }
        }
      }
    );
    assert.equal(createdCalendarEvent.created, true);
    const calendarEventId = createdCalendarEvent.item.id;
    const updatedCalendarEvent = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/collections/events/${calendarEventId}`,
      {
        token,
        method: "PATCH",
        body: { item: { title: "Updated design review" } }
      }
    );
    assert.equal(updatedCalendarEvent.item.title, "Updated design review");
    const populatedCalendarSurface = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/view-document?route=events`,
      { token }
    );
    assert.equal(populatedCalendarSurface.items[0].temporal.startsAt, "2026-07-29T09:00:00+09:00");
    const deletedCalendarEvent = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/collections/events/${calendarEventId}`,
      { token, method: "DELETE" }
    );
    assert.equal(deletedCalendarEvent.deleted, true);
    const memoSurface = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/view-document?route=memos`,
      { token }
    );
    assert.equal(memoSurface.schemaVersion, 2);
    assert.equal(memoSurface.presentation, "collection");
    assert.equal(memoSurface.editor.collection, "memos");
    const createdMemo = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/collections/memos`,
      {
        token,
        method: "POST",
        body: {
          item: {
            title: "빠른 메모",
            content: "Planner 안의 간단한 텍스트 기록",
            pinned: true
          }
        }
      }
    );
    assert.equal(createdMemo.created, true);
    const populatedMemoSurface = await fetchJson(
      `${baseUrl}/api/plugins/com.codmes.planner/view-document?route=memos`,
      { token }
    );
    assert.equal(populatedMemoSurface.items[0].title, "빠른 메모");
    assert.equal(populatedMemoSurface.items[0].body, "Planner 안의 간단한 텍스트 기록");
    assert.equal(populatedMemoSurface.items[0].filterValues.pinned, "true");
    assert.equal(populatedMemoSurface.items[0].editorValues.pinned, true);

    const documentJobs = await fetchJson(`${baseUrl}/api/document-jobs`, { token });
    assert.deepEqual(documentJobs.jobs, []);

    await fs.writeFile(path.join(workspaceRoot, "Notes", "auth-note.md"), "# Token Test\n", "utf8");
    const rebuilt = await fetchJson(`${baseUrl}/api/index/rebuild`, { token, method: "POST" });
    assert.equal(rebuilt.ok, true);
    assert.equal(rebuilt.itemCount, 1);

    const metadata = await fetchJson(`${baseUrl}/api/file/metadata?path=Notes/auth-note.md`, { token });
    assert.equal(metadata.path, "Notes/auth-note.md");
    assert.equal(metadata.kind, "markdown");

    await fs.mkdir(path.join(workspaceRoot, "Notes", "Work", "Docs"), { recursive: true });
    await fs.writeFile(path.join(workspaceRoot, "Notes", "Work", "README.md"), "# Work\n", "utf8");
    await fs.writeFile(path.join(workspaceRoot, "Notes", "Work", "Docs", "Architecture.md"), "# Architecture\n", "utf8");
    const directTree = await fetchJson(`${baseUrl}/api/tree?root=notes`, { token });
    assert.equal(directTree.children.some((item) => item.path === "Notes/Work"), true);
    assert.equal(directTree.children.some((item) => item.path === "Notes/Work/README.md"), false);
    const recursiveTree = await fetchJson(`${baseUrl}/api/tree?root=notes&recursive=true`, { token });
    assert.equal(recursiveTree.children.some((item) => item.path === "Notes/Work/README.md"), true);
    assert.equal(recursiveTree.children.some((item) => item.path === "Notes/Work/Docs/Architecture.md"), true);

    await fs.writeFile(path.join(workspaceRoot, "Documents", "sample.pdf"), "%PDF-1.4\n%%EOF", "utf8");
    const rawRange = await fetch(`${baseUrl}/api/raw?path=Documents/sample.pdf`, {
      headers: {
        authorization: `Bearer ${token}`,
        range: "bytes=0-3"
      }
    });
    assert.equal(rawRange.status, 206);
    assert.equal(rawRange.headers.get("accept-ranges"), "bytes");
    assert.equal(rawRange.headers.get("content-range"), "bytes 0-3/14");
    assert.equal(await rawRange.text(), "%PDF");
    const rawHead = await fetch(`${baseUrl}/api/raw?path=Documents/sample.pdf`, {
      method: "HEAD",
      headers: { authorization: `Bearer ${token}` }
    });
    assert.equal(rawHead.status, 200);
    assert.equal(rawHead.headers.get("content-length"), "14");
    assert.equal(await rawHead.text(), "");
    const emptyAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/sample.pdf`, { token });
    assert.equal(emptyAnnotations.documentPath, "Documents/sample.pdf");
    assert.equal(emptyAnnotations.pages.length, 0);
    const savedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/sample.pdf`, {
      token,
      method: "PUT",
      body: {
        schemaVersion: 1,
        pages: [
          {
            pageIndex: 0,
            inkDataBase64: "cGVuLWRhdGE=",
            inkStrokes: [
              {
                id: "stroke-1",
                tool: "pen",
                color: "#111111",
                width: 2.5,
                points: [
                  { x: 0.1, y: 0.2, pressure: 0.5, timeOffset: 0 },
                  { x: 0.2, y: 0.25, pressure: 0.6, timeOffset: 0.01 }
                ]
              }
            ],
            objects: [
              { id: "highlight-1", type: "highlight", bbox: { x: 0.1, y: 0.2, width: 0.3, height: 0.04 } }
            ]
          }
        ]
      }
    });
    assert.equal(savedAnnotations.documentPath, "Documents/sample.pdf");
    assert.equal(savedAnnotations.pages[0].pageIndex, 0);
    const readAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/sample.pdf`, { token });
    assert.equal(readAnnotations.pages[0].inkDataBase64, "cGVuLWRhdGE=");
    assert.equal(readAnnotations.pages[0].inkStrokes[0].points[1].x, 0.2);
    await fs.access(annotationsPathForDocument(workspaceRoot, "Documents/sample.pdf"));
    assert.equal(
      annotationsPathForDocument(workspaceRoot, "Documents/sample.pdf"),
      path.join(documentStateDirectory(workspaceRoot, "Documents/sample.pdf"), "annotations.json")
    );
    await fs.access(documentManifestPath(workspaceRoot, "Documents/sample.pdf"));

    const movedPdf = await fetchJson(`${baseUrl}/api/file/move`, {
      token,
      method: "PATCH",
      body: { from: "Documents/sample.pdf", to: "Documents/renamed.pdf" }
    });
    assert.equal(movedPdf.to, "Documents/renamed.pdf");
    const movedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/renamed.pdf`, { token });
    assert.equal(movedAnnotations.documentPath, "Documents/renamed.pdf");
    assert.equal(movedAnnotations.pages[0].inkDataBase64, "cGVuLWRhdGE=");
    await fs.access(annotationsPathForDocument(workspaceRoot, "Documents/renamed.pdf"));
    await fs.access(documentManifestPath(workspaceRoot, "Documents/renamed.pdf"));
    await assert.rejects(
      fs.access(documentStateDirectory(workspaceRoot, "Documents/sample.pdf")),
      { code: "ENOENT" }
    );

    const copiedPdf = await fetchJson(`${baseUrl}/api/file/copy`, {
      token,
      method: "POST",
      body: { from: "Documents/renamed.pdf", to: "Documents/copied.pdf" }
    });
    assert.equal(copiedPdf.to, "Documents/copied.pdf");
    const copiedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/copied.pdf`, { token });
    assert.equal(copiedAnnotations.documentPath, "Documents/copied.pdf");
    assert.equal(copiedAnnotations.pages[0].inkDataBase64, "cGVuLWRhdGE=");
    await fs.access(documentManifestPath(workspaceRoot, "Documents/copied.pdf"));

    const deletedCopy = await fetchJson(`${baseUrl}/api/file?path=Documents/copied.pdf`, {
      token,
      method: "DELETE"
    });
    assert.equal(deletedCopy.path, "Documents/copied.pdf");
    await assert.rejects(
      fs.access(documentStateDirectory(workspaceRoot, "Documents/copied.pdf")),
      { code: "ENOENT" }
    );

    await fs.writeFile(path.join(workspaceRoot, "Documents", "imported.pdf"), "%PDF-1.4\nexisting\n%%EOF", "utf8");
    const imported = await fetchJson(`${baseUrl}/api/file/import-codmes-pdf`, {
      token,
      method: "POST",
      body: {
        path: "Documents/imported.pdf",
        pdfDataBase64: Buffer.from("%PDF-1.4\nimported\n%%EOF", "utf8").toString("base64"),
        codmesDataBase64: Buffer.from(JSON.stringify({
          schemaVersion: 1,
          documentPath: "Portable/old.pdf",
          pages: [{
            pageIndex: 0,
            objects: [{ id: "portable-text", type: "text", text: "portable import marker" }]
          }],
          objects: []
        }), "utf8").toString("base64")
      }
    });
    assert.equal(imported.requestedPath, "Documents/imported.pdf");
    assert.equal(imported.path, "Documents/imported 2.pdf");
    assert.equal(imported.renamed, true);
    assert.equal(imported.annotationsImported, true);
    const importedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/imported%202.pdf`, { token });
    assert.equal(importedAnnotations.documentPath, "Documents/imported 2.pdf");
    assert.equal(importedAnnotations.pages[0].objects[0].text, "portable import marker");

    const editableExport = await fetchJson(`${baseUrl}/api/file/export-codmes-pdf`, {
      token,
      method: "POST",
      body: {
        name: "portable.pdf",
        pdfDataBase64: Buffer.from("%PDF-1.4\nportable package\n%%EOF", "utf8").toString("base64"),
        codmesDataBase64: Buffer.from(JSON.stringify({
          schemaVersion: 2,
          documentPath: "Documents/original.pdf",
          pages: [{
            pageIndex: 0,
            objects: [{ id: "package-text", type: "text", text: "editable package marker" }]
          }],
          objects: [],
          elements: []
        }), "utf8").toString("base64")
      }
    });
    assert.equal(editableExport.fileName, "portable.codmespdf");

    const restoredPackage = await fetchJson(`${baseUrl}/api/file/import-codmes-pdf-package`, {
      token,
      method: "POST",
      body: {
        path: "Documents/portable.pdf",
        packageDataBase64: editableExport.dataBase64
      }
    });
    assert.equal(restoredPackage.path, "Documents/portable.pdf");
    assert.equal(restoredPackage.annotationsImported, true);
    const restoredAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/portable.pdf`, { token });
    assert.equal(restoredAnnotations.documentPath, "Documents/portable.pdf");
    assert.equal(restoredAnnotations.pages[0].objects[0].text, "editable package marker");

    const restoredCollision = await fetchJson(`${baseUrl}/api/file/import-codmes-pdf-package`, {
      token,
      method: "POST",
      body: {
        path: "Documents/portable.pdf",
        packageDataBase64: editableExport.dataBase64
      }
    });
    assert.equal(restoredCollision.path, "Documents/portable 2.pdf");
    assert.equal(restoredCollision.renamed, true);

    const invalidPackageResponse = await fetch(`${baseUrl}/api/file/import-codmes-pdf-package`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json"
      },
      body: JSON.stringify({
        path: "Documents/broken.pdf",
        packageDataBase64: Buffer.from("not a zip", "utf8").toString("base64")
      })
    });
    assert.equal(invalidPackageResponse.status, 400);
    await assert.rejects(fs.access(path.join(workspaceRoot, "Documents", "broken.pdf")), { code: "ENOENT" });

    await fs.mkdir(path.join(workspaceRoot, "Documents", ".codmes", "annotations"), { recursive: true });
    await fs.writeFile(path.join(workspaceRoot, "Documents", ".codmes", "annotations", "later.codmes.json"), JSON.stringify({
      schemaVersion: 1,
      documentPath: "Documents/later.pdf",
      pages: [{
        pageIndex: 0,
        objects: [{ id: "state-first", type: "text", text: "state arrived first" }]
      }],
      objects: []
    }), "utf8");
    await fs.writeFile(path.join(workspaceRoot, "Documents", "later.pdf"), "%PDF-1.4\nlater\n%%EOF", "utf8");
    const stateFirstAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/later.pdf`, { token });
    assert.equal(stateFirstAnnotations.pages[0].objects[0].text, "state arrived first");

    const replacedPdf = await fetchJson(`${baseUrl}/api/file/binary`, {
      token,
      method: "PUT",
      body: {
        path: "Documents/later.pdf",
        dataBase64: Buffer.from("%PDF-1.4\nreplaced\n%%EOF", "utf8").toString("base64")
      }
    });
    assert.equal(replacedPdf.path, "Documents/later.pdf");
    assert.equal(await fs.readFile(path.join(workspaceRoot, "Documents", "later.pdf"), "utf8"), "%PDF-1.4\nreplaced\n%%EOF");

    await Promise.all(["a", "b", "c"].map((name) => fetchJson(`${baseUrl}/api/file/upload`, {
      token,
      method: "POST",
      body: {
        path: `Notes/concurrent-${name}.md`,
        dataBase64: Buffer.from(`# Concurrent ${name}\nshared-upload-token-${name}\n`, "utf8").toString("base64")
      }
    })));
    await Promise.all(["a", "b", "c"].map((name) => fetchJson(`${baseUrl}/api/file?path=Notes/concurrent-${name}.md`, {
      token,
      method: "PUT",
      body: {
        content: `# Concurrent ${name}\nshared-upload-token-${name}\nmodified-token-${name}\n`
      }
    })));
    const concurrentSearch = await fetchJson(`${baseUrl}/api/search`, {
      token,
      method: "POST",
      body: { query: "modified-token-b", scopePath: "Notes", maxResults: 10 }
    });
    assert.equal(concurrentSearch.results.some((result) => result.path === "Notes/concurrent-b.md"), true);

    const security = await fetchJson(`${baseUrl}/api/security`, { token });
    assert.equal(security.approvalMode, "auto");
    const updatedSecurity = await fetchJson(`${baseUrl}/api/security`, {
      token,
      method: "POST",
      body: { approvalMode: "manual", requireApproval: ["mcp.tool.call"] }
    });
    assert.equal(updatedSecurity.security.approvalMode, "manual");

    const addedMcp = await fetchJson(`${baseUrl}/api/mcp`, {
      token,
      method: "POST",
      body: { name: "test_mcp", command: "node", args: ["server.js"], scopePath: "Notes" }
    });
    assert.equal(addedMcp.server.name, "test_mcp");
    assert.equal(addedMcp.server.scopePath, "Notes");
    const upsertedMcp = await fetchJson(`${baseUrl}/api/mcp`, {
      token,
      method: "POST",
      body: { name: "test_mcp", command: "node", args: ["updated.js"], enabled: true, scopePath: "Code" }
    });
    assert.equal(upsertedMcp.created, false);
    assert.equal(upsertedMcp.server.scopePath, "Code");
    assert.deepEqual(upsertedMcp.server.args, ["updated.js"]);
    assert.equal(upsertedMcp.server.enabled, true);
    const updatedMcp = await fetchJson(`${baseUrl}/api/mcp/test_mcp`, {
      token,
      method: "POST",
      body: {
        command: "example-mcp",
        args: ["start", "--scope", "Notes"],
        enabled: true,
        env: { EXAMPLE_MCP_MODE: "demo" },
        scopePath: "Notes/Research"
      }
    });
    assert.equal(updatedMcp.server.command, "example-mcp");
    assert.equal(updatedMcp.server.scopePath, "Notes/Research");
    assert.equal(updatedMcp.server.env.EXAMPLE_MCP_MODE, "demo");
    assert.deepEqual(updatedMcp.server.args, ["start", "--scope", "Notes"]);
    const remoteMcp = await fetchJson(`${baseUrl}/api/mcp`, {
      token,
      method: "POST",
      body: {
        name: "knu-rag",
        transport: "streamable_http",
        url: "https://example.test/api/mcp/",
        credential_id: "knu-rag",
        surfaces: ["chat"]
      }
    });
    assert.equal(remoteMcp.server.transport, "streamable_http");
    assert.equal(remoteMcp.server.credentialConfigured, false);
    assert.equal(Object.hasOwn(remoteMcp.server, "token"), false);
    assert.equal(JSON.stringify(remoteMcp).includes("bearer"), false);
    const listedMcp = await fetchJson(`${baseUrl}/api/mcp`, { token });
    assert.equal(typeof listedMcp.servers.find((server) => server.name === "test_mcp").enabled, "boolean");
    const disabled = await fetchJson(`${baseUrl}/api/mcp/test_mcp/disable`, { token, method: "POST" });
    assert.equal(disabled.server.enabled, false);
    const removed = await fetchJson(`${baseUrl}/api/mcp/test_mcp`, { token, method: "DELETE" });
    assert.equal(removed.removed, "test_mcp");

    const searchConfig = await fetchJson(`${baseUrl}/api/search/config`, {
      token,
      method: "POST",
      body: {
        roots: ["Notes", "Code"],
        embeddingsProvider: "openai",
        openaiBaseUrl: "http://127.0.0.1:11434/v1",
        openaiApiKey: "ollama",
        openaiEmbedModel: "bge-m3",
        openaiEmbedDim: 1024,
        vlmProvider: "ollama-local",
        vlmModel: "gemma4:e2b-mlx",
        vlmBaseUrl: "http://127.0.0.1:11434/v1",
        vlmApiKey: "ollama"
      }
    });
    assert.equal(searchConfig.ok, true);
    assert.equal(searchConfig.openaiEmbedModel, "bge-m3");
    assert.equal(searchConfig.openaiApiKeyConfigured, true);
    assert.equal(searchConfig.vlmProvider, "ollama-local");
    assert.equal(searchConfig.vlmModel, "gemma4:e2b-mlx");
    assert.equal(searchConfig.vlmApiKeyConfigured, true);
    assert.equal(searchConfig.backend, "codmes");
    assert.match(searchConfig.configPath, /search\.env$/);

    const doctor = await fetchJson(`${baseUrl}/api/doctor`, { token });
    assert.equal(doctor.ok, true);
    assert.equal(doctor.authRequired, true);
    assert.equal(doctor.audit.path, ".codmes/audit/audit.jsonl");
    assert.equal(doctor.documentIngest.requirements, "server/workers/document-ingest/requirements.txt");
    assert.equal(typeof doctor.documentIngest.libraries.fitz, "boolean");
    assert.equal(Object.hasOwn(doctor.documentIngest, "binaries"), false);

    const providers = await fetchJson(`${baseUrl}/api/providers`, { token });
    assert.equal(providers.providers.some((provider) => provider.id === "custom"), false);
    assert.equal(providers.providers.some((provider) => provider.id === "openai-api"), false);
    assert.ok(providers.providers.some((provider) => provider.id === "openai-codex"));
    assert.ok(providers.providers.some((provider) => provider.id === "ollama-local"));

    const openAiModels = await fetchJson(`${baseUrl}/api/providers/openai-codex/models`, { token });
    assert.equal(openAiModels.provider, "openai-codex");
    assert.ok(openAiModels.models.includes("gpt-5.6-sol"));
    assert.ok(openAiModels.models.includes("gpt-5.6-terra"));
    assert.ok(openAiModels.models.includes("gpt-5.6-luna"));
    assert.ok(openAiModels.models.includes("gpt-5.4-mini"));

    const storedAuth = await fetchJson(`${baseUrl}/api/auth/ollama-local`, {
      token,
      method: "POST",
      body: {
        baseUrl: "http://127.0.0.1:11434"
      }
    });
    assert.equal(storedAuth.ok, true);
    assert.equal(storedAuth.provider, "ollama-local");

    const authStatus = await fetchJson(`${baseUrl}/api/auth`, { token });
    const ollamaAuth = authStatus.providers.find((provider) => provider.provider === "ollama-local");
    assert.equal(ollamaAuth.configured, true);

    const providerAuth = await fetchJson(`${baseUrl}/api/auth/ollama-local`, { token });
    assert.equal(providerAuth.provider, "ollama-local");
    assert.equal(providerAuth.credentials.length, 1);
    assert.equal(providerAuth.credentials[0].baseUrl, "http://127.0.0.1:11434");

    const defaultModel = await fetchJson(`${baseUrl}/api/model/default`, {
      token,
      method: "POST",
      body: { provider: "ollama-local", model: "demo-model" }
    });
    assert.equal(defaultModel.defaultModel.provider, "ollama-local");
    assert.equal(defaultModel.defaultModel.model, "demo-model");

    const readDefault = await fetchJson(`${baseUrl}/api/model/default`, { token });
    assert.equal(readDefault.defaultModel.id, "ollama-local:demo-model");

    const models = await fetchJson(`${baseUrl}/api/models`, { token });
    assert.ok(models.models.some((model) => model.id === "ollama-local:demo-model"));

    const removedAuth = await fetchJson(`${baseUrl}/api/auth/ollama-local`, {
      token,
      method: "DELETE"
    });
    assert.equal(removedAuth.removed, true);
    const providerAuthAfterDelete = await fetchJson(`${baseUrl}/api/auth/ollama-local`, { token });
    assert.equal(providerAuthAfterDelete.credentials.length, 0);
  } finally {
    server.kill("SIGTERM");
    await fs.rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("plugin package owns UI while the upstream returns data only", async () => {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-api-"));
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-package-"));
  const codmesPort = 28000 + Math.floor(Math.random() * 5000);
  const token = "workspace-secret";
  const upstreamRequests = [];
  const expectedDocument = {
    schemaVersion: 1,
    presentation: "dashboard",
    title: "Portal",
    subtitle: "Student data",
    search: null,
    filters: [],
    emptyState: null,
    items: [],
    sections: [{
      id: "timetable",
      title: "Timetable",
      subtitle: null,
      systemImage: "calendar",
      kind: "table",
      columns: ["Period", "Monday"],
      rows: [["1", "Data Structures"]]
    }]
  };
  const upstreamData = {
    student: { name: "Test Student" },
    timetable: {
      columns: ["Period", "Monday"],
      rows: [["1", "Data Structures"]]
    }
  };
  const upstream = http.createServer((req, res) => {
    upstreamRequests.push({ url: req.url, authorization: req.headers.authorization, cookie: req.headers.cookie });
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(upstreamData));
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const upstreamPort = upstream.address().port;
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.portal",
    version: "1.0.0",
    name: "Portal",
    platforms: ["macos", "ios"],
    surface: {
      id: "portal",
      type: "declarative",
      upstreamUrl: `http://127.0.0.1:${upstreamPort}`,
      entryPath: "/api/portal-data",
      ui: "surface.json"
    },
    mcp: {
      name: "portal",
      transport: "streamable_http",
      url: `http://127.0.0.1:${upstreamPort}/api/mcp`,
      surfaces: ["portal"],
      allowUnauthenticated: true
    }
  }), "utf8");
  await fs.writeFile(path.join(source, "surface.json"), JSON.stringify({
    schemaVersion: 1,
    routes: [{
      id: "portal",
      title: "Portal",
      dataSources: [{ id: "api", path: "/api/portal-data" }],
      document: {
        schemaVersion: 1,
        presentation: "dashboard",
        title: "Portal",
        subtitle: { literal: "Student data" },
        filters: [],
        emptyState: null,
        sections: [{
          id: { literal: "timetable" },
          title: { literal: "Timetable" },
          systemImage: "calendar",
          kind: "table",
          columns: { path: "$.api.timetable.columns" },
          rows: { path: "$.api.timetable.rows" }
        }]
      }
    }]
  }), "utf8");
  const server = spawn(process.execPath, ["server/index.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      NODE_ENV: "test",
      CODMES_HOST: "127.0.0.1",
      CODMES_PORT: String(codmesPort),
      CODMES_WORKSPACE_ROOT: workspaceRoot,
      CODMES_SERVER_TOKEN: token
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  try {
    const baseUrl = `http://127.0.0.1:${codmesPort}`;
    await waitForServer(`${baseUrl}/api/health`);
    const unauthorized = await fetch(`${baseUrl}/api/plugins`);
    assert.equal(unauthorized.status, 401);
    await fetchJson(`${baseUrl}/api/plugins/install`, {
      token,
      method: "POST",
      body: { path: source }
    });
    const plugins = await fetchJson(`${baseUrl}/api/plugins`, { token });
    const registeredPlugin = plugins.plugins.find(
      (plugin) => plugin.id === "com.example.portal"
    );
    const registeredSurface = registeredPlugin.views.find((view) => view.id === "portal");
    assert.equal(registeredSurface?.renderer, "declarative");
    assert.equal(registeredSurface?.dataPath, "/api/plugins/com.example.portal/view-document");

    const document = await fetchJson(
      `${baseUrl}/api/plugins/com.example.portal/view-document`,
      { token }
    );
    assert.deepEqual(document, expectedDocument);
    assert.deepEqual(upstreamRequests.map((request) => request.url), ["/api/portal-data"]);
    assert.equal(upstreamRequests.every((request) => request.authorization === undefined), true);
    assert.equal(upstreamRequests.every((request) => request.cookie === undefined), true);

    await new Promise((resolve) => upstream.close(resolve));
    const unavailableDocument = await fetchJson(
      `${baseUrl}/api/plugins/com.example.portal/view-document`,
      { token }
    );
    assert.equal(unavailableDocument.title, "Portal");
    assert.equal(unavailableDocument.presentation, "dashboard");
    assert.deepEqual(unavailableDocument.items, []);
    assert.deepEqual(unavailableDocument.sections, []);
    assert.deepEqual(unavailableDocument.dataState, {
      status: "unavailable",
      errors: [{
        sourceId: "api",
        message: "The plugin service is unavailable. Check that it is running and retry.",
        retryable: true
      }]
    });

    const removed = await fetchJson(`${baseUrl}/api/plugins/com.example.portal`, {
      token,
      method: "DELETE"
    });
    assert.equal(removed.removed, true);
  } finally {
    server.kill("SIGTERM");
    if (upstream.listening) {
      await new Promise((resolve) => upstream.close(resolve));
    }
    await fs.rm(workspaceRoot, { recursive: true, force: true });
    await fs.rm(source, { recursive: true, force: true });
  }
});

async function waitForServer(url) {
  let lastError;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw lastError || new Error(`Server did not become ready: ${url}`);
}

async function fetchJson(url, options = {}) {
  const headers = { accept: "application/json" };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.body) headers["content-type"] = "application/json";
  const response = await fetch(url, {
    method: options.method || "GET",
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${text}`);
  }
  return text ? JSON.parse(text) : {};
}
