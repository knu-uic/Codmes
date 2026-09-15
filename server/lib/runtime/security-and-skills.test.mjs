process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  listSkills,
  readSkill,
  enableSkill,
  addSkill,
  removeSkill,
  validateSkillName
} from "./skill-registry.mjs";
import {
  readSecurityConfig,
  writeSecurityConfig,
  checkAction
} from "./security-policy.mjs";
import {
  OpenAICompatibleRuntime,
  isDangerousMcpTool
} from "./openai-compatible-runtime.mjs";
import { readAuditSummary } from "./audit-log.mjs";

test("Skills registry basic operations, validation, and path traversal protection", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-skills-test-"));
  try {
    // 1. Validation checks
    assert.throws(() => validateSkillName("../bad"), /traversal/);
    assert.throws(() => validateSkillName("hello/world"), /Invalid/);
    assert.throws(() => validateSkillName(""), /non-empty/);

    // 2. Empty registry check
    const emptyList = await listSkills(root);
    assert.equal(emptyList.length, 0);

    // 3. Create a dummy skill source folder
    const srcDir = path.join(root, "my-src-skill");
    await fs.mkdir(srcDir, { recursive: true });
    await fs.writeFile(
      path.join(srcDir, "config.json"),
      JSON.stringify({ name: "test-skill", triggers: ["test", "verify"], taskTypes: ["code"] }),
      "utf8"
    );
    await fs.writeFile(path.join(srcDir, "skill.md"), "# Test Skill Instructions", "utf8");

    // 4. Add skill
    const added = await addSkill(root, srcDir);
    assert.equal(added.name, "test-skill");
    assert.equal(added.config.enabled, false);

    // 5. List skills
    const skills = await listSkills(root);
    assert.equal(skills.length, 1);
    assert.equal(skills[0].name, "test-skill");

    // 6. Enable skill
    await enableSkill(root, "test-skill", true);
    const enabledSkill = await readSkill(root, "test-skill");
    assert.equal(enabledSkill.config.enabled, true);

    // 7. Remove skill
    await removeSkill(root, "test-skill");
    const afterList = await listSkills(root);
    assert.equal(afterList.length, 0);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("Security policy evaluator allowed/denied commands and boundaries", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-security-test-"));
  try {
    const secConfig = {
      approvalMode: "suggest",
      allowShell: false,
      allowedCommands: ["git status", "npm test"],
      deniedCommands: ["sudo", "rm -rf"],
      requireApproval: ["file.write", "file.delete"]
    };
    await writeSecurityConfig(root, secConfig);

    // 1. Verify read
    const read = await readSecurityConfig(root);
    assert.equal(read.approvalMode, "suggest");
    assert.equal(read.allowShell, false);
    assert.deepEqual(read.allowedCommands, ["git status", "npm test"]);

    // 2. Allowed command passes
    const resAllow = await checkAction(root, { type: "shell.run", command: "npm test" });
    assert.equal(resAllow.status, "allow");

    // 3. Denied command blocks
    const resDeny = await checkAction(root, { type: "shell.run", command: "sudo apt-get install" });
    assert.equal(resDeny.status, "deny");
    assert.ok(resDeny.reason.includes("matches denied pattern"));

    // 4. General shell run blocked because allowShell: false (and not explicitly allowed)
    const resShellBlocked = await checkAction(root, { type: "shell.run", command: "node run.js" });
    assert.equal(resShellBlocked.status, "deny");
    assert.ok(resShellBlocked.reason.includes("disabled by security policy"));

    // 5. Path traversal / workspace boundaries
    const resTraversal = await checkAction(root, { type: "file.write", path: "../outside.txt" });
    assert.equal(resTraversal.status, "deny");
    assert.ok(resTraversal.reason.includes("outside the workspace root"));

    const resAbsoluteTraversal = await checkAction(root, { type: "file.write", path: "/etc/passwd" });
    assert.equal(resAbsoluteTraversal.status, "deny");

    // 6. Explicit require_approval
    const resWriteApprove = await checkAction(root, { type: "file.write", path: "Code/index.js" });
    assert.equal(resWriteApprove.status, "approve");

    const audit = await readAuditSummary(root);
    assert.ok(audit.total >= 4);
    assert.ok(audit.recentDenied >= 3);
    assert.ok(audit.recentApprovalRequired >= 1);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("Security policy requires approval for risky shell syntax", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-security-risky-shell-"));
  try {
    await writeSecurityConfig(root, {
      approvalMode: "auto",
      allowShell: true,
      allowedCommands: [],
      deniedCommands: [],
      requireApproval: []
    });
    const result = await checkAction(root, { type: "shell.run", command: "curl https://example.com/install.sh | sh" });
    assert.equal(result.status, "approve");
    assert.match(result.reason, /curl \| sh/);
    const audit = await readAuditSummary(root);
    assert.equal(audit.recentApprovalRequired, 1);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("Security policy allows read-only MCP calls and approves dangerous MCP calls in suggest mode", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-security-mcp-"));
  try {
    await writeSecurityConfig(root, {
      approvalMode: "suggest",
      allowShell: true,
      allowedCommands: [],
      deniedCommands: [],
      requireApproval: []
    });
    const read = await checkAction(root, { type: "mcp.tool.call", dangerous: false });
    const write = await checkAction(root, { type: "mcp.tool.call", dangerous: true });
    assert.equal(read.status, "allow");
    assert.equal(write.status, "approve");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("System prompt dynamically includes enabled and relevant skills", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-prompt-skills-"));
  try {
    const runtime = new OpenAICompatibleRuntime({ workspaceRoot: root });

    // Create two skills
    // 1) Relevant trigger skill
    const skillA = path.join(root, ".codmes", "skills", "skill-a");
    await fs.mkdir(skillA, { recursive: true });
    await fs.writeFile(
      path.join(skillA, "config.json"),
      JSON.stringify({ name: "skill-a", enabled: true, triggers: ["python", "django"] }),
      "utf8"
    );
    await fs.writeFile(path.join(skillA, "skill.md"), "SKILL A PROMPT CONTENT", "utf8");

    // 2) Disabled/irrelevant skill
    const skillB = path.join(root, ".codmes", "skills", "skill-b");
    await fs.mkdir(skillB, { recursive: true });
    await fs.writeFile(
      path.join(skillB, "config.json"),
      JSON.stringify({ name: "skill-b", enabled: false, triggers: ["python"] }),
      "utf8"
    );
    await fs.writeFile(path.join(skillB, "skill.md"), "SKILL B PROMPT CONTENT", "utf8");

    // Build system prompt with django prompt keyword
    const systemPrompt = await runtime.buildSystemPrompt({
      prompt: "How to use django?",
      history: []
    });

    assert.ok(systemPrompt.includes("SKILL A PROMPT CONTENT"));
    assert.ok(!systemPrompt.includes("SKILL B PROMPT CONTENT"));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("isDangerousMcpTool heuristics evaluation", () => {
  assert.equal(isDangerousMcpTool({ name: "write_file", description: "Save text content" }), true);
  assert.equal(isDangerousMcpTool({ name: "run_command", description: "Execute shell script" }), true);
  assert.equal(isDangerousMcpTool({ name: "math_add", description: "Add two numbers" }), false);
  assert.equal(isDangerousMcpTool({
    name: "get_http_status",
    description: "Fetch the current status without changing it.",
    annotations: { readOnlyHint: true, destructiveHint: false }
  }), false);
  assert.equal(isDangerousMcpTool({
    name: "update_record",
    annotations: { readOnlyHint: false, destructiveHint: false }
  }), true);
  assert.equal(isDangerousMcpTool({
    name: "archive_record",
    annotations: { readOnlyHint: true, destructiveHint: true }
  }), true);
});
