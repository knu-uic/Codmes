import test from "node:test";
import assert from "node:assert/strict";
import { renderCodeDocument, renderMarkdownBody, renderMarkdownDocument } from "./render-service.mjs";

test("renders fenced code with shiki markup", async () => {
  const html = await renderMarkdownBody("```python\nprint('hi')\n```");
  assert.match(html, /class="shiki/);
  assert.match(html, /print/);
});

test("escapes raw html in markdown", async () => {
  const html = await renderMarkdownBody("<script>alert(1)</script>");
  assert.match(html, /&lt;script&gt;/);
  assert.doesNotMatch(html, /<script>/);
});

test("drops unsafe link protocols", async () => {
  const html = await renderMarkdownBody("[bad](javascript:alert(1))");
  assert.doesNotMatch(html, /href="javascript:/);
  assert.match(html, /bad/);
});

test("renders safe remote images and blocks unsafe image URLs", async () => {
  const safe = await renderMarkdownBody("![그림 1](http://127.0.0.1:8000/api/notice-assets/1/content)");
  const unsafe = await renderMarkdownBody("![bad](javascript:alert(1))");

  assert.match(safe, /<img src="http:\/\/127\.0\.0\.1:8000\/api\/notice-assets\/1\/content"/);
  assert.doesNotMatch(unsafe, /<img/);
  assert.doesNotMatch(unsafe, /javascript:/);
});

test("returns complete html document", async () => {
  const html = await renderMarkdownDocument("# Title");
  assert.match(html, /<!doctype html>/);
  assert.match(html, /<h1>Title<\/h1>/);
});

test("renders standalone code documents with shiki", async () => {
  const html = await renderCodeDocument("func greet() { print(\"hi\") }", { language: "swift" });
  assert.match(html, /class="markdown-body code-document"/);
  assert.match(html, /class="shiki/);
  assert.match(html, /print/);
});
