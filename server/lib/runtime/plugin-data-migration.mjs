import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import { validatePluginCollectionItem } from "./plugin-collection-store.mjs";

const FIELD_PATTERN = /^[A-Za-z_][A-Za-z0-9_-]{0,63}$/;
const COLLECTION_PATTERN = /^[a-z][a-z0-9_-]{0,63}$/;

export function normalizePluginMigrations(value) {
  if (value == null) return [];
  const document = Array.isArray(value) ? { schemaVersion: 1, migrations: value } : value;
  if (!document || typeof document !== "object" || Array.isArray(document)
      || Number(document.schemaVersion) !== 1 || !Array.isArray(document.migrations)) {
    throw new Error("Plugin migrations document schema is invalid.");
  }
  const migrations = document.migrations.map((migration) => {
    const id = String(migration?.id || "").trim();
    const from = Number(migration?.from);
    const to = Number(migration?.to);
    if (!/^[A-Za-z0-9_.-]{1,64}$/.test(id)
        || !Number.isInteger(from) || from < 1 || to !== from + 1
        || !Array.isArray(migration.operations) || !migration.operations.length) {
      throw new Error("Plugin data migration must have an id, adjacent versions, and operations.");
    }
    return {
      id,
      from,
      to,
      operations: migration.operations.map(normalizeMigrationOperation)
    };
  });
  if (new Set(migrations.map((migration) => migration.id)).size !== migrations.length
      || new Set(migrations.map((migration) => migration.from)).size !== migrations.length) {
    throw new Error("Plugin data migrations must have unique ids and source versions.");
  }
  return migrations.sort((a, b) => a.from - b.from);
}

export async function preparePluginDataMigration(
  workspaceRoot,
  previousManifest,
  nextManifest,
  previousDataVersion
) {
  const from = Number(previousDataVersion || previousManifest?.dataVersion || 1);
  const to = Number(nextManifest.dataVersion || 1);
  if (to < from) {
    throw Object.assign(new Error("Plugin updates cannot downgrade the data schema."), {
      status: 409,
      code: "plugin_data_downgrade"
    });
  }
  if (to === from || !previousManifest) return noMigration(from);
  const steps = [];
  let current = from;
  while (current < to) {
    const step = nextManifest.migrations.find((migration) => migration.from === current);
    if (!step) {
      throw Object.assign(
        new Error(`Plugin is missing data migration ${current} → ${current + 1}.`),
        { status: 409, code: "plugin_migration_missing" }
      );
    }
    steps.push(step);
    current = step.to;
  }

  const collectionIds = new Set(
    steps.flatMap((step) => step.operations.map((operation) => operation.collection))
  );
  const snapshots = new Map();
  const nextStates = new Map();
  for (const collectionId of collectionIds) {
    const file = collectionPath(workspaceRoot, nextManifest.id, collectionId);
    let raw = null;
    let state = { schemaVersion: 1, revision: 0, items: [] };
    try {
      raw = await fs.readFile(file);
      state = JSON.parse(raw.toString("utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    snapshots.set(collectionId, raw);
    nextStates.set(collectionId, JSON.parse(JSON.stringify(state)));
  }

  for (const step of steps) {
    for (const operation of step.operations) {
      const state = nextStates.get(operation.collection);
      if (!state) continue;
      state.items = state.items.map((item) => applyOperation(item, operation));
    }
  }
  for (const [collectionId, state] of nextStates) {
    const collection = nextManifest.storage?.collections?.find((item) => item.id === collectionId);
    if (!collection) {
      throw new Error(`Migration targets undeclared collection '${collectionId}'.`);
    }
    state.items = state.items.map((item) => ({
      ...validatePluginCollectionItem(item, collection.itemSchema),
      id: item.id
    }));
  }

  let applied = false;
  return {
    from,
    to,
    steps: steps.map((step) => step.id),
    async apply() {
      try {
        for (const [collectionId, state] of nextStates) {
          await writeState(workspaceRoot, nextManifest.id, collectionId, state);
        }
        applied = true;
      } catch (error) {
        await restoreSnapshots(workspaceRoot, nextManifest.id, snapshots);
        throw error;
      }
    },
    async rollback() {
      if (applied) await restoreSnapshots(workspaceRoot, nextManifest.id, snapshots);
      applied = false;
    }
  };
}

function normalizeMigrationOperation(value) {
  const type = String(value?.type || "").trim();
  const collection = String(value?.collection || "").trim();
  const field = String(value?.field || value?.from || "").trim();
  if (!COLLECTION_PATTERN.test(collection)
      || !["renameField", "setDefault", "removeField"].includes(type)
      || !FIELD_PATTERN.test(field)) {
    throw new Error("Plugin data migration operation is invalid.");
  }
  if (type === "renameField") {
    const target = String(value.to || "").trim();
    if (!FIELD_PATTERN.test(target) || target === field) {
      throw new Error("renameField requires a different valid target field.");
    }
    return { type, collection, from: field, to: target };
  }
  if (type === "setDefault") {
    if (!Object.hasOwn(value, "value") || !isScalar(value.value)) {
      throw new Error("setDefault requires a scalar value.");
    }
    return { type, collection, field, value: value.value };
  }
  return { type, collection, field };
}

function applyOperation(item, operation) {
  const next = { ...item };
  if (operation.type === "renameField") {
    if (Object.hasOwn(next, operation.from) && !Object.hasOwn(next, operation.to)) {
      next[operation.to] = next[operation.from];
    }
    delete next[operation.from];
  } else if (operation.type === "setDefault") {
    if (next[operation.field] == null) next[operation.field] = operation.value;
  } else {
    delete next[operation.field];
  }
  return next;
}

function isScalar(value) {
  return value === null || ["string", "number", "boolean"].includes(typeof value);
}

function collectionPath(root, pluginId, collectionId) {
  return path.join(root, ".codmes", "plugin-data", pluginId, `${collectionId}.json`);
}

async function writeState(root, pluginId, collectionId, state) {
  const target = collectionPath(root, pluginId, collectionId);
  await fs.mkdir(path.dirname(target), { recursive: true });
  const next = {
    ...state,
    schemaVersion: 1,
    revision: Number(state.revision || 0) + 1,
    updatedAt: new Date().toISOString()
  };
  const temporary = `${target}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  await fs.writeFile(temporary, JSON.stringify(next, null, 2) + "\n", "utf8");
  await fs.rename(temporary, target);
}

async function restoreSnapshots(root, pluginId, snapshots) {
  for (const [collectionId, raw] of snapshots) {
    const target = collectionPath(root, pluginId, collectionId);
    if (raw == null) {
      await fs.rm(target, { force: true });
    } else {
      await fs.mkdir(path.dirname(target), { recursive: true });
      const temporary = `${target}.${crypto.randomBytes(6).toString("hex")}.restore`;
      await fs.writeFile(temporary, raw);
      await fs.rename(temporary, target);
    }
  }
}

function noMigration(version) {
  return {
    from: version,
    to: version,
    steps: [],
    async apply() {},
    async rollback() {}
  };
}
