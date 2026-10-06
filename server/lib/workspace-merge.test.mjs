import test from "node:test";
import assert from "node:assert/strict";
import { mergeText, mergeAnnotations } from "./workspace-merge.mjs";

test("different lines including adjacent replacements merge, overlapping line is incoming", () => {
  assert.equal(mergeText("a\nb\nc\n", "A\nB\nc\n", "a\nlatest B\nC\n"), "A\nlatest B\nC\n");
  assert.equal(mergeText("a\nb\n", "phone\nb\n", "tablet\nb\n"), "tablet\nb\n");
  assert.equal(mergeText("a\r\nb", "A\r\nb", "a\r\nB"), "A\r\nB");
});
test("inserts, deletes, identical inserts and unchanged stale uploads", () => {
  assert.equal(mergeText("a\nb\nc\n", "a\nphone\nb\nc\n", "a\nb\ntablet\nc\n"), "a\nphone\nb\ntablet\nc\n");
  assert.equal(mergeText("a\n", "phone\na\n", "tablet\na\n"), "phone\ntablet\na\n");
  assert.equal(mergeText("a\n", "same\na\n", "same\na\n"), "same\na\n");
  assert.equal(mergeText("a\nb\nc\n", "a\nc\n", "a\nb\nC\n"), "a\nC\n");
  assert.equal(mergeText("base", "remote", "base"), "remote");
  assert.equal(mergeText("a\nb\n", "A\nb\n", "a\n"), "A\n");
});
const box = (id, text) => ({ id, type: "text", text });
const stroke = (id) => ({ id, tool: "pen", points: [{ x: 0.1, y: 0.2 }] });
const doc = (pages, objects = [], elements = []) => ({ schemaVersion: 2, pages, objects, elements });
test("PDF edits on different pages and different IDs on the same page both survive", () => {
  const base = doc([{ pageIndex: 0, objects: [box("a", "base")], inkStrokes: [] }, { pageIndex: 1, objects: [] }]);
  const remote = structuredClone(base), incoming = structuredClone(base);
  remote.pages[0].objects[0].text = "phone";
  remote.pages[0].inkStrokes.push(stroke("phone-ink"));
  incoming.pages[0].objects.push(box("new", "tablet addition"));
  incoming.pages[0].inkStrokes.push(stroke("tablet-ink"));
  incoming.pages[1].objects.push(box("page2", "page two"));
  const merged = mergeAnnotations(base, remote, incoming, "Notes/book.pdf");
  assert.deepEqual(merged.pages[0].objects, [box("a", "phone"), box("new", "tablet addition")]);
  assert.deepEqual(merged.pages[0].inkStrokes.map(x => x.id), ["phone-ink", "tablet-ink"]);
  assert.equal(merged.pages[1].objects[0].text, "page two");
});
test("same text box is incoming; deletion, addition and unchanged stale objects are independent", () => {
  const base = doc([{ pageIndex: 0, objects: [box("a", "base"), box("b", "base"), box("c", "base")] }]);
  const remote = structuredClone(base), incoming = structuredClone(base);
  remote.pages[0].objects = [box("a", "phone"), box("b", "remote"), box("c", "remote"), box("new", "new")];
  incoming.pages[0].objects = [box("a", "latest"), box("b", "base")];
  const merged = mergeAnnotations(base, remote, incoming, "Notes/book.pdf");
  assert.deepEqual(merged.pages[0].objects, [box("a", "latest"), box("b", "remote"), box("new", "new")]);
});
test("structured stroke unions invalidate derived PencilKit bytes, not other pages", () => {
  const base = doc([{ pageIndex: 0, inkStrokes: [], inkDataBase64: "old" }, { pageIndex: 1, inkDataBase64: "untouched" }]);
  const remote = structuredClone(base), incoming = structuredClone(base);
  remote.pages[0] = { pageIndex: 0, inkStrokes: [stroke("a")], inkDataBase64: "phone" };
  incoming.pages[0] = { pageIndex: 0, inkStrokes: [stroke("b")], inkDataBase64: "tablet" };
  const merged = mergeAnnotations(base, remote, incoming, "Notes/book.pdf");
  assert.equal(merged.pages[0].inkDataBase64, undefined);
  assert.equal(merged.pages[1].inkDataBase64, "untouched");
});
test("root elements and object IDs merge, duplicate IDs are rejected", () => {
  const base = doc([], [box("a", "base")], [{ id: "e", text: "base" }]);
  const remote = doc([], [box("a", "remote")], [{ id: "e", text: "remote" }]);
  const incoming = doc([], [box("a", "latest"), box("b", "added")], [{ id: "e", text: "base" }, { id: "new", text: "new" }]);
  const merged = mergeAnnotations(base, remote, incoming, "Notes/book.pdf");
  assert.equal(merged.objects[0].text, "latest");
  assert.deepEqual(merged.elements.map(e => e.text), ["remote", "new"]);
  assert.throws(() => mergeAnnotations(base, remote, doc([], [box("x", "a"), box("x", "b")]), "Notes/book.pdf"));
});
