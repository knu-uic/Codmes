process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { executeWorkspaceTool } from "./workspace-tools.mjs";
import { documentIngestCacheDirectory } from "../document-ingest.mjs";

test("Workspace tools return extracted document text and related images instead of PDF bytes", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-workspace-tools-document-"));
  const relativePath = "Notes/study.pdf";
  const absolutePath = path.join(root, relativePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, "%PDF binary placeholder", "utf8");
  const stat = await fs.stat(absolutePath);
  const cacheDirectory = documentIngestCacheDirectory(root, relativePath);
  await fs.mkdir(cacheDirectory, { recursive: true });
  const relatedImage = {
    asset_id: "d1234567890abcdef1234567",
    reference: "[그림:d1234567890abcdef1234567]",
    url: "/api/document-assets/study--12345678/figure.png"
  };
  await fs.writeFile(path.join(cacheDirectory, "extraction.json"), JSON.stringify({
    schemaVersion: 15,
    path: relativePath,
    kind: "pdf",
    text: "DBMS 플랫폼 계층도",
    markdown: "# DBMS 플랫폼 계층도",
    blocks: [{ page: 1, text: "DBMS 플랫폼 계층도", metadata: { related_images: [relatedImage] } }],
    cache: { version: 15, sourcePath: relativePath, size: stat.size, mtimeMs: stat.mtimeMs }
  }), "utf8");

  const file = await executeWorkspaceTool(root, "read_note_file", { path: relativePath });

  assert.equal(file.content, "# DBMS 플랫폼 계층도");
  assert.deepEqual(file.related_images, [relatedImage]);
  assert.doesNotMatch(file.content, /%PDF/);
});

test("Workspace tools route code surface operations through CodeAgentRuntime", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-workspace-tools-code-"));
  const calls = [];
  const codeRuntime = {
    resolveCodeScope(scopePath = "Code") {
      calls.push(["resolveCodeScope", scopePath]);
      return {
        relativePath: scopePath,
        absolutePath: path.join(root, scopePath)
      };
    },
    async searchProject(scope, query, options) {
      calls.push(["searchProject", scope.relativePath, query, options.maxSearchResults]);
      return { resultCount: 1, results: [{ path: "Code/a.js", snippet: "hello" }] };
    },
    async applyPatch(taskId, params) {
      calls.push(["applyPatch", taskId, params.proposalId, params.approved]);
      return { ok: true, taskId, proposalId: params.proposalId };
    }
  };

  const search = await executeWorkspaceTool(root, "search_project", {
    query: "hello",
    scopePath: "Code/demo",
    maxResults: 7
  }, { codeRuntime });
  assert.equal(search.resultCount, 1);

  const patch = await executeWorkspaceTool(root, "apply_patch", {
    taskId: "task-1",
    proposalId: "patch-1"
  }, { codeRuntime, approved: true });
  assert.equal(patch.ok, true);

  assert.deepEqual(calls, [
    ["resolveCodeScope", "Code/demo"],
    ["searchProject", "Code/demo", "hello", 7],
    ["applyPatch", "task-1", "patch-1", true]
  ]);
});

test("Workspace tools reject code surface operations without CodeAgentRuntime", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-workspace-tools-no-code-runtime-"));
  await assert.rejects(
    () => executeWorkspaceTool(root, "search_project", { query: "hello" }),
    /requires CodeAgentRuntime/
  );
});

test("Workspace tools read project files only under Code", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-workspace-tools-read-code-"));
  await fs.mkdir(path.join(root, "Code"), { recursive: true });
  await fs.mkdir(path.join(root, "Notes"), { recursive: true });
  await fs.writeFile(path.join(root, "Code", "a.js"), "console.log('ok');", "utf8");
  await fs.writeFile(path.join(root, "Notes", "a.md"), "# note", "utf8");

  const file = await executeWorkspaceTool(root, "read_project_file", {
    path: "Code/a.js"
  }, {
    codeRuntime: {}
  });
  assert.equal(file.path, "Code/a.js");
  assert.match(file.content, /console/);

  await assert.rejects(
    () => executeWorkspaceTool(root, "read_project_file", { path: "Notes/a.md" }, { codeRuntime: {} }),
    /only read files under the current code scope 'Code'/
  );
});

test("Workspace tools use current code scope and task id defaults", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-workspace-tools-code-scope-"));
  await fs.mkdir(path.join(root, "Projects", "demo"), { recursive: true });
  await fs.mkdir(path.join(root, "Projects", "other"), { recursive: true });
  await fs.writeFile(path.join(root, "Projects", "demo", "a.js"), "console.log('demo');", "utf8");
  await fs.writeFile(path.join(root, "Projects", "other", "b.js"), "console.log('other');", "utf8");

  const calls = [];
  const codeRuntime = {
    async proposePatch(taskId, params) {
      calls.push(["proposePatch", taskId, params.changes.length]);
      return { ok: true, taskId };
    }
  };

  const file = await executeWorkspaceTool(root, "read_project_file", {
    path: "Projects/demo/a.js"
  }, {
    codeRuntime,
    currentCodeScopePath: "Projects/demo"
  });
  assert.equal(file.path, "Projects/demo/a.js");

  await assert.rejects(
    () => executeWorkspaceTool(root, "read_project_file", { path: "Projects/other/b.js" }, {
      codeRuntime,
      currentCodeScopePath: "Projects/demo"
    }),
    /current code scope 'Projects\/demo'/
  );

  const patch = await executeWorkspaceTool(root, "propose_patch", {
    changes: [{ operation: "write", path: "a.js", content: "x" }]
  }, {
    codeRuntime,
    currentCodeTaskId: "task-current"
  });
  assert.equal(patch.taskId, "task-current");
  assert.deepEqual(calls, [["proposePatch", "task-current", 1]]);
});
