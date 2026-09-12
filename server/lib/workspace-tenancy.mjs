import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const WORKSPACE_DIRECTORIES = ["Notes", "Documents", "Code", "Attachments", ".codmes"];

export class WorkspaceTenancyStore {
  constructor(database, dataRoot, options = {}) {
    this.database = database;
    this.dataRoot = path.resolve(dataRoot);
    this.legacyWorkspaceRoot = options.legacyWorkspaceRoot
      ? path.resolve(options.legacyWorkspaceRoot)
      : null;
  }

  workspaceRoot(storageKey, rootPath = null) {
    if (rootPath) {
      const resolved = path.resolve(rootPath);
      if (!this.legacyWorkspaceRoot || resolved !== this.legacyWorkspaceRoot) {
        throw Object.assign(new Error("Workspace root is outside the configured Codmes data directories."), { status: 500 });
      }
      return resolved;
    }
    if (!/^[a-f0-9-]{36}$/i.test(String(storageKey || ""))) {
      throw Object.assign(new Error("Invalid workspace storage key."), { status: 400 });
    }
    return path.join(this.dataRoot, "workspaces", storageKey, "files");
  }

  async createWorkspace(user, { name, adoptLegacy = false }) {
    const workspaceName = String(name || "").normalize("NFKC").trim().slice(0, 120);
    if (!workspaceName) throw Object.assign(new Error("Workspace name is required."), { status: 400 });
    const id = randomUUID();
    const storageKey = randomUUID();
    const rootPath = adoptLegacy && this.legacyWorkspaceRoot ? this.legacyWorkspaceRoot : null;
    await this.database.transaction(async (client) => {
      await client.query(
        `INSERT INTO codmes_workspaces(id, owner_user_id, name, storage_key, root_path)
         VALUES ($1, $2, $3, $4, $5)`,
        [id, user.id, workspaceName, storageKey, rootPath]
      );
      await client.query(
        `INSERT INTO codmes_workspace_members(workspace_id, user_id, role)
         VALUES ($1, $2, 'owner')`,
        [id, user.id]
      );
    });
    const root = this.workspaceRoot(storageKey, rootPath);
    await Promise.all(WORKSPACE_DIRECTORIES.map((directory) => fs.mkdir(path.join(root, directory), { recursive: true })));
    return { id, name: workspaceName, role: "owner", root };
  }

  async listForUser(userId) {
    const result = await this.database.query(
      `SELECT w.id, w.name, w.storage_key, w.root_path, m.role, w.created_at, w.updated_at
         FROM codmes_workspace_members m
         JOIN codmes_workspaces w ON w.id = m.workspace_id
        WHERE m.user_id = $1
        ORDER BY w.created_at, w.id`,
      [userId]
    );
    return result.rows.map((row) => ({
      id: row.id,
      name: row.name,
      role: row.role,
      root: this.workspaceRoot(row.storage_key, row.root_path),
      createdAt: row.created_at,
      updatedAt: row.updated_at
    }));
  }

  async resolveForUser(userId, workspaceId, requiredRole = "viewer") {
    const result = await this.database.query(
      `SELECT w.id, w.name, w.storage_key, w.root_path, m.role
         FROM codmes_workspace_members m
         JOIN codmes_workspaces w ON w.id = m.workspace_id
        WHERE m.user_id = $1 AND w.id = $2`,
      [userId, workspaceId]
    );
    const row = result.rows[0];
    if (!row || !roleAllows(row.role, requiredRole)) {
      throw Object.assign(new Error("Workspace not found."), { status: 404 });
    }
    return {
      id: row.id,
      name: row.name,
      role: row.role,
      root: this.workspaceRoot(row.storage_key, row.root_path)
    };
  }

  async resolveByIdInternal(workspaceId) {
    const result = await this.database.query(
      "SELECT id, name, storage_key, root_path FROM codmes_workspaces WHERE id = $1",
      [workspaceId]
    );
    const row = result.rows[0];
    if (!row) return null;
    return {
      id: row.id,
      name: row.name,
      role: "owner",
      root: this.workspaceRoot(row.storage_key, row.root_path)
    };
  }

  async addMember(actor, workspaceId, userId, role = "viewer") {
    if (!new Set(["editor", "viewer"]).has(role)) {
      throw Object.assign(new Error("Invalid workspace role."), { status: 400 });
    }
    await this.resolveForUser(actor.id, workspaceId, "owner");
    await this.database.query(
      `INSERT INTO codmes_workspace_members(workspace_id, user_id, role)
       VALUES ($1, $2, $3)
       ON CONFLICT (workspace_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
      [workspaceId, userId, role]
    );
    return { workspaceId, userId, role };
  }
}

export function roleAllows(actual, required) {
  const rank = { viewer: 1, editor: 2, owner: 3 };
  return (rank[actual] || 0) >= (rank[required] || 0);
}
