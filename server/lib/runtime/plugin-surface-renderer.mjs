import crypto from "node:crypto";

const BLOCKED_PATH_SEGMENTS = new Set(["__proto__", "prototype", "constructor"]);

export function renderPluginSurfaceDocument(route, payloads) {
  if (!route?.document || !payloads || typeof payloads !== "object") {
    throw new Error("Plugin Surface binding requires a route and data payloads.");
  }
  const binding = route.document;
  const document = {
    schemaVersion: Number(binding.schemaVersion) || 1,
    presentation: binding.presentation,
    title: String(binding.title || route.title || ""),
    subtitle: renderValue(binding.subtitle, payloads, payloads) || null,
    search: binding.search || null,
    filters: Array.isArray(binding.filters) ? binding.filters : [],
    emptyState: binding.emptyState || null,
    items: [],
    ...(binding.editor
      ? { editor: JSON.parse(JSON.stringify(binding.editor)) }
      : {}),
    ...(binding.presentation === "dashboard" ? { sections: [] } : {})
  };

  if (binding.presentation === "collection" || binding.presentation === "calendar") {
    document.items = renderCollection(binding.collection, payloads, binding.editor);
  } else {
    document.sections = renderSections(binding.sections, payloads);
  }
  return document;
}

function renderCollection(binding, payloads, editor = null) {
  if (!binding || typeof binding !== "object") return [];
  const items = [];
  if (binding.source && binding.item) {
    const source = readPath(payloads, binding.source);
    if (Array.isArray(source)) {
      for (const value of source.slice(0, 500)) {
        items.push(renderItem(binding.item, value, payloads, editor));
      }
    }
  }
  if (Array.isArray(binding.staticItems)) {
    for (const item of binding.staticItems) {
      items.push(renderItem(item, payloads, payloads, editor));
    }
  }
  return items.filter((item) => item.title);
}

function renderItem(binding, value, payloads, editor = null) {
  const actionUrl = renderValue(binding.action?.url, value, payloads);
  const idValue = renderValue(binding.id, value, payloads)
    || crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex").slice(0, 24);
  const tags = (Array.isArray(binding.tags) ? binding.tags : [])
    .flatMap((spec) => {
      const resolved = resolveRaw(spec, value, payloads);
      return Array.isArray(resolved) ? resolved : [resolved];
    })
    .map(stringValue)
    .filter(Boolean);
  const filterValues = {};
  for (const [key, spec] of Object.entries(binding.filterValues || {})) {
    filterValues[key] = renderValue(spec, value, payloads);
  }
  const item = {
    id: String(idValue),
    title: renderValue(binding.title, value, payloads),
    subtitle: renderValue(binding.subtitle, value, payloads) || null,
    body: renderValue(binding.body, value, payloads) || null,
    tags,
    filterValues,
    action: actionUrl ? { type: "openURL", url: actionUrl } : null
  };
  if (binding.temporal && typeof binding.temporal === "object") {
    item.temporal = {
      startsAt: renderValue(binding.temporal.startsAt, value, payloads),
      endsAt: renderValue(binding.temporal.endsAt, value, payloads) || null,
      allDay: Boolean(resolveRaw(binding.temporal.allDay, value, payloads))
    };
  }
  if (editor?.fields) {
    item.editorValues = Object.fromEntries(
      editor.fields.flatMap((field) => {
        const resolved = readPath(value, field.id);
        return ["string", "number", "boolean"].includes(typeof resolved)
          ? [[field.id, resolved]]
          : [];
      })
    );
  }
  return item;
}

function renderSections(bindings, payloads) {
  const sections = [];
  for (const binding of Array.isArray(bindings) ? bindings : []) {
    if (binding.kind === "keyValue") {
      const fields = renderFields(binding.fields, payloads, payloads);
      if (fields.length || binding.includeWhenEmpty === true) {
        sections.push(sectionBase(binding, payloads, { kind: "keyValue", fields }));
      }
    } else if (binding.kind === "table") {
      const columns = renderStringArray(resolveRaw(binding.columns, payloads, payloads));
      const rows = renderRows(resolveRaw(binding.rows, payloads, payloads), columns.length);
      if (rows.length || binding.includeWhenEmpty === true) {
        sections.push(sectionBase(binding, payloads, { kind: "table", columns, rows }));
      }
    } else if (binding.kind === "keyValueGroup") {
      const source = readPath(payloads, binding.source);
      for (const [index, value] of (Array.isArray(source) ? source : []).entries()) {
        const fieldsValue = resolveRaw(binding.fields || "fields", value, payloads);
        const fields = Array.isArray(fieldsValue)
          ? fieldsValue.map((field, fieldIndex) => ({
              id: String(field.id || `${index}-${fieldIndex}`),
              label: stringValue(field.label),
              value: stringValue(field.value)
            })).filter((field) => field.label && field.value)
          : [];
        if (fields.length) {
          sections.push(sectionBase(binding, value, {
            id: renderValue(binding.id, value, payloads) || `key-values-${index}`,
            title: renderValue(binding.title, value, payloads),
            kind: "keyValue",
            fields
          }, payloads));
        }
      }
    } else if (binding.kind === "tableGroup") {
      const source = readPath(payloads, binding.source);
      for (const [index, value] of (Array.isArray(source) ? source : []).entries()) {
        const columns = renderStringArray(resolveRaw(binding.columns || "columns", value, payloads));
        const rows = renderRows(resolveRaw(binding.rows || "rows", value, payloads), columns.length);
        if (rows.length) {
          sections.push(sectionBase(binding, value, {
            id: renderValue(binding.id, value, payloads) || `table-${index}`,
            title: renderValue(binding.title, value, payloads),
            kind: "table",
            columns,
            rows
          }, payloads));
        }
      }
    }
  }
  return sections.slice(0, 50);
}

function sectionBase(binding, value, override = {}, payloads = value) {
  return {
    id: override.id || renderValue(binding.id, value, payloads),
    title: override.title || renderValue(binding.title, value, payloads),
    subtitle: renderValue(binding.subtitle, value, payloads) || null,
    systemImage: String(binding.systemImage || "") || null,
    ...override
  };
}

function renderFields(bindings, value, payloads) {
  return (Array.isArray(bindings) ? bindings : []).map((field, index) => ({
    id: String(field.id || index),
    label: String(field.label || ""),
    value: renderValue(field.value, value, payloads)
  })).filter((field) => field.label && field.value);
}

function renderRows(value, width) {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 1000).map((row) => {
    const cells = renderStringArray(row);
    return width ? cells.slice(0, width).concat(Array(Math.max(0, width - cells.length)).fill("")) : cells;
  });
}

function renderStringArray(value) {
  return Array.isArray(value) ? value.map(stringValue) : [];
}

function renderValue(spec, value, payloads) {
  const raw = resolveRaw(spec, value, payloads);
  if (Array.isArray(raw)) return raw.map(stringValue).filter(Boolean).join(", ");
  return stringValue(raw);
}

function resolveRaw(spec, value, payloads) {
  if (spec == null) return "";
  if (typeof spec === "string") return readPath(value, spec);
  if (typeof spec !== "object" || Array.isArray(spec)) return spec;
  if (Object.hasOwn(spec, "literal")) return spec.literal;
  if (Array.isArray(spec.coalesce)) {
    for (const candidate of spec.coalesce) {
      const resolved = resolveRaw(candidate, value, payloads);
      if (resolved != null && resolved !== "") return resolved;
    }
    return spec.default ?? "";
  }
  if (Array.isArray(spec.join)) {
    return spec.join
      .map((part) => renderValue(part, value, payloads))
      .filter(Boolean)
      .join(String(spec.separator || " · "));
  }
  const root = String(spec.path || "").startsWith("$") ? payloads : value;
  const path = String(spec.path || "").replace(/^\$\.?/, "");
  let resolved = readPath(root, path);
  if (typeof resolved === "boolean"
      && Object.hasOwn(spec, resolved ? "trueValue" : "falseValue")) {
    resolved = spec[resolved ? "trueValue" : "falseValue"];
  }
  if ((resolved == null || resolved === "") && Object.hasOwn(spec, "default")) {
    resolved = spec.default;
  }
  if (spec.suffix) {
    const text = stringValue(resolved);
    return text ? `${text}${spec.suffix}` : "";
  }
  return resolved;
}

function readPath(value, path) {
  if (!path) return value;
  let current = value;
  for (const segment of String(path).split(".").filter(Boolean)) {
    if (BLOCKED_PATH_SEGMENTS.has(segment) || current == null) return undefined;
    if (Array.isArray(current) && /^\d+$/.test(segment)) {
      current = current[Number(segment)];
    } else if (typeof current === "object" && Object.hasOwn(current, segment)) {
      current = current[segment];
    } else {
      return undefined;
    }
  }
  return current;
}

function stringValue(value) {
  if (value == null) return "";
  if (typeof value === "boolean") return value ? "예" : "아니요";
  return String(value);
}
