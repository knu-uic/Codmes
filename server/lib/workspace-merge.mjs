import { isDeepStrictEqual as equal } from "node:util";

// Preserve line endings and the final-newline distinction.
const lines = (text) => text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
function edits(base, value, splitReplacements = true) {
  let prefix = 0, suffix = 0;
  while (prefix < base.length && prefix < value.length && base[prefix] === value[prefix]) prefix++;
  while (suffix < base.length - prefix && suffix < value.length - prefix && base[base.length - 1 - suffix] === value[value.length - 1 - suffix]) suffix++;
  const a = base.slice(prefix, base.length - suffix), b = value.slice(prefix, value.length - suffix);
  // Bound memory/CPU for large or entirely replaced documents. Caller falls back to LWW.
  if ((a.length + 1) * (b.length + 1) > 4_000_000) return null;
  const width = b.length + 1, table = new Uint32Array((a.length + 1) * width);
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) {
    table[i * width + j] = a[i] === b[j] ? 1 + table[(i + 1) * width + j + 1] : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
  }
  const result = []; let i = 0, j = 0, pending;
  const flush = () => {
    if (!pending) return;
    // Adjacent line replacements remain separate conflict units.
    if (splitReplacements && pending.end - pending.start === pending.text.length) pending.text.forEach((line, n) => result.push({ start: pending.start + n, end: pending.start + n + 1, text: [line] }));
    else result.push(pending);
    pending = undefined;
  };
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) { flush(); i++; j++; }
    else {
      pending ??= { start: prefix + i, end: prefix + i, text: [] };
      if (j < b.length && (i === a.length || table[i * width + j + 1] >= table[(i + 1) * width + j])) pending.text.push(b[j++]);
      else { i++; pending.end = prefix + i; }
    }
  }
  flush(); return result;
}
const overlaps = (a, b) => a.start === a.end && b.start === b.end ? a.start === b.start
  : a.start === a.end ? a.start > b.start && a.start < b.end
  : b.start === b.end ? b.start > a.start && b.start < a.end
  : a.start < b.end && b.start < a.end;
function render(base, start, end, changes) {
  let cursor = start; const out = [];
  for (const change of changes) { out.push(...base.slice(cursor, change.start), ...change.text); cursor = change.end; }
  out.push(...base.slice(cursor, end)); return out;
}

/** Three-way line merge. Incoming wins ONLY overlapping ranges; distinct insertions survive. */
export function mergeText(baseText, currentText, incomingText, { precise = false } = {}) {
  if (incomingText === baseText || currentText === incomingText) return currentText;
  if (currentText === baseText) return incomingText;
  const base = lines(baseText), remote = edits(base, lines(currentText)), local = edits(base, lines(incomingText));
  if (!remote || !local) {
    if (precise) throw Object.assign(new Error("This text change is too large to merge safely."), { status: 409 });
    return incomingText;
  }
  const all = [...remote.map(e => ({ ...e, side: 0 })), ...local.map(e => ({ ...e, side: 1 }))].sort((a, b) => a.start - b.start || a.end - b.end || a.side - b.side);
  const groups = [];
  for (const edit of all) {
    const matching = groups.filter(g => g.some(e => overlaps(e, edit)));
    if (!matching.length) groups.push([edit]);
    else {
      const group = [...matching.flat(), edit];
      for (const old of matching) groups.splice(groups.indexOf(old), 1);
      groups.push(group);
    }
  }
  const merged = groups.map(group => {
    const start = Math.min(...group.map(e => e.start)), end = Math.max(...group.map(e => e.end));
    const incoming = group.filter(e => e.side === 1).sort((a, b) => a.start - b.start);
    const existing = group.filter(e => e.side === 0).sort((a, b) => a.start - b.start);
    let text = render(base, start, end, incoming.length ? incoming : existing);
    if (precise && start !== end && incoming.length && existing.length) {
      text = [mergeCharacters(base.slice(start, end).join(""), render(base, start, end, existing).join(""), text.join(""))];
    }
    if (start === end && incoming.length && existing.length) {
      const before = render(base, start, end, existing);
      if (!equal(before, text)) text = [...before, ...text];
    }
    return { start, end, text };
  }).sort((a, b) => a.start - b.start || a.end - b.end);
  return render(base, 0, base.length, merged).join("");
}

// Refine ONLY overlapping line hunks. Word boundaries avoid synthesizing broken
// words from two concurrent replacements; punctuation/emoji stay separate units.
// Oversized ambiguous hunks stay pending instead of silently replacing a document.
const graphemes = new Intl.Segmenter("und", { granularity: "word" });
function mergeCharacters(baseText, currentText, incomingText) {
  if (incomingText === baseText || incomingText === currentText) return currentText;
  if (currentText === baseText) return incomingText;
  const chars = text => Array.from(graphemes.segment(text), item => item.segment);
  const base = chars(baseText), a = edits(base, chars(currentText), false), b = edits(base, chars(incomingText), false);
  if (!a || !b) throw Object.assign(new Error("This overlapping text change is too large to merge safely."), { status: 409 });
  const groups = [];
  for (const edit of [...a.map(e => ({ ...e, side: 0 })), ...b.map(e => ({ ...e, side: 1 }))].sort((x, y) => x.start - y.start || x.end - y.end)) {
    const matches = groups.filter(group => group.some(other => overlaps(edit, other)));
    if (!matches.length) groups.push([edit]);
    else { const group = [...matches.flat(), edit]; for (const match of matches) groups.splice(groups.indexOf(match), 1); groups.push(group); }
  }
  const merged = groups.map(group => {
    const start = Math.min(...group.map(e => e.start)), end = Math.max(...group.map(e => e.end));
    const local = group.filter(e => e.side === 1).sort((x, y) => x.start - y.start), remote = group.filter(e => e.side === 0).sort((x, y) => x.start - y.start);
    let text = render(base, start, end, local.length ? local : remote);
    if (start === end && local.length && remote.length) {
      const before = render(base, start, end, remote);
      if (!equal(before, text)) text = [...before, ...text];
    }
    return { start, end, text };
  }).sort((x, y) => x.start - y.start || x.end - y.end);
  return render(base, 0, base.length, merged).join("");
}

function keyed(values, key) {
  const map = new Map();
  for (const value of values ?? []) {
    if (!value || typeof value !== "object" || !(key in value) || map.has(value[key])) throw new Error(`Invalid or duplicate annotation ${key}.`);
    map.set(value[key], value);
  }
  return map;
}
function mergeItems(base, current, incoming, key = "id", mergeItem) {
  const b = keyed(base, key), c = keyed(current, key), i = keyed(incoming, key), out = [];
  for (const id of new Set([...c.keys(), ...i.keys(), ...b.keys()])) {
    const before = b.get(id), remote = c.get(id), local = i.get(id);
    // Absence relative to the ancestor is a deletion, not a whole-document replacement.
    const chosen = equal(local, before) ? remote : equal(remote, before) || equal(local, remote) ? local
      : mergeItem && local && remote ? mergeItem(before ?? {}, remote, local) : local;
    if (chosen !== undefined) out.push(chosen);
  }
  return out;
}
function mergeFields(base, current, incoming, excluded) {
  const out = {};
  for (const key of new Set([...Object.keys(current), ...Object.keys(incoming), ...Object.keys(base)])) {
    if (excluded.has(key)) continue;
    const value = equal(incoming[key], base[key]) ? current[key] : incoming[key];
    if (value !== undefined) out[key] = value;
  }
  return out;
}
function mergePage(base, current, incoming) {
  const out = mergeFields(base, current, incoming, new Set(["objects", "elements", "inkStrokes"]));
  for (const key of ["objects", "elements", "inkStrokes"]) {
    if ([base, current, incoming].some(doc => Array.isArray(doc[key]))) out[key] = mergeItems(base[key], current[key], incoming[key]);
  }
  // PencilKit bytes represent a whole page, not individually mergeable strokes.
  // When structured strokes changed, those are authoritative; discard only the derived rendering.
  if (Array.isArray(out.inkStrokes) && !equal(out.inkStrokes, incoming.inkStrokes) && !equal(out.inkStrokes, current.inkStrokes)) delete out.inkDataBase64;
  return out;
}

// Geometry tuples and stroke point arrays are atomic; unrelated properties merge.
// Text boxes use a scalar text register: concurrent replacements choose the latest edit.
function mergeEntity(base, current, incoming) {
  const out = {};
  for (const key of new Set([...Object.keys(base), ...Object.keys(current), ...Object.keys(incoming)])) {
    const b = base[key], c = current[key], i = incoming[key];
    const nested = !["bbox", "transform", "points"].includes(key) && [b ?? {}, c, i].every(v => v && typeof v === "object" && !Array.isArray(v));
    const value = equal(i, b) ? c : equal(c, b) || equal(c, i) ? i : nested ? mergeEntity(b ?? {}, c, i) : i;
    if (value !== undefined) Object.defineProperty(out, key, { value, enumerable: true, configurable: true, writable: true });
  }
  return out;
}

export function mergeAnnotationsPrecise(base, current, incoming, documentPath, modifiedAt) {
  const pageKey = page => page.pageId ?? `index:${page.pageIndex}`;
  const pageMap = doc => {
    const result = new Map();
    for (const page of doc.pages ?? []) {
      const id = pageKey(page);
      if (result.has(id)) throw new Error("Duplicate annotation page ID.");
      result.set(id, page);
    }
    return result;
  };
  const b = pageMap(base), c = pageMap(current), i = pageMap(incoming);
  const out = mergeEntity(base, current, incoming);
  out.pages = [];
  const mergePageProperties = (before, remote, local) => {
    const page = mergeEntity(before, remote, local);
    for (const key of ["objects", "elements", "inkStrokes"]) {
      if ([before, remote, local].some(doc => Array.isArray(doc[key]))) page[key] = mergeItems(before[key], remote[key], local[key], "id", mergeEntity);
    }
    if (Array.isArray(page.inkStrokes) && !equal(page.inkStrokes, local.inkStrokes) && !equal(page.inkStrokes, remote.inkStrokes)) delete page.inkDataBase64;
    return page;
  };
  for (const id of new Set([...c.keys(), ...i.keys(), ...b.keys()])) {
    const before = b.get(id), remote = c.get(id), local = i.get(id);
    const page = equal(local, before) ? remote : equal(remote, before) || equal(local, remote) ? local
      : local && remote ? mergePageProperties(before ?? {}, remote, local) : local;
    if (page) out.pages.push(page);
  }
  out.pages.sort((x, y) => x.pageIndex - y.pageIndex || pageKey(x).localeCompare(pageKey(y)));
  for (const key of ["objects", "elements"]) if ([base, current, incoming].some(doc => Array.isArray(doc[key]))) out[key] = mergeItems(base[key], current[key], incoming[key], "id", mergeEntity);
  out.documentPath = documentPath;
  out.updatedAt = modifiedAt;
  return out;
}

/** Pages are containers; text boxes, strokes, elements are independent stable-ID units. */
export function mergeAnnotations(base, current, incoming, documentPath) {
  const out = mergeFields(base, current, incoming, new Set(["pages", "objects", "elements"]));
  out.pages = mergeItems(base.pages, current.pages, incoming.pages, "pageIndex", mergePage).sort((a, b) => a.pageIndex - b.pageIndex);
  for (const key of ["objects", "elements"]) {
    if ([base, current, incoming].some(doc => Array.isArray(doc[key]))) out[key] = mergeItems(base[key], current[key], incoming[key]);
  }
  out.documentPath = documentPath;
  out.updatedAt = new Date().toISOString();
  return out;
}
