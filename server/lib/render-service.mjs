import { Renderer, marked } from "marked";
import { codeToHtml } from "shiki";

const SAFE_CODE_PREFIX = "__AI_WORKSPACE_SAFE_CODE__:";

const LANGUAGE_ALIASES = new Map(Object.entries({
  bash: "shellscript",
  cjs: "javascript",
  h: "c",
  hpp: "cpp",
  js: "javascript",
  jsx: "jsx",
  kt: "kotlin",
  kts: "kotlin",
  md: "markdown",
  mjs: "javascript",
  py: "python",
  rb: "ruby",
  rs: "rust",
  sh: "shellscript",
  shell: "shellscript",
  ts: "typescript",
  tsx: "tsx",
  yml: "yaml",
  zsh: "shellscript"
}));

export async function renderMarkdownDocument(markdown, options = {}) {
  const body = await renderMarkdownBody(markdown, options);
  return htmlDocument(body);
}

export async function renderCodeDocument(code, options = {}) {
  const language = normalizeLanguage(options.language);
  const body = await highlightedCodeBlock(String(code ?? ""), language, options);
  return htmlDocument(body, { kind: "code" });
}

export async function renderMarkdownBody(markdown, options = {}) {
  const tokens = marked.lexer(String(markdown ?? ""), {
    gfm: true,
    breaks: false
  });
  await replaceCodeTokens(tokens, options);
  return marked.parser(tokens, {
    gfm: true,
    renderer: safeRenderer()
  });
}

async function replaceCodeTokens(tokens, options) {
  for (const token of tokens) {
    if (token.type === "code") {
      const lang = normalizeLanguage(token.lang);
      const highlighted = await highlightedCodeBlock(token.text, lang, options);
      token.type = "html";
      token.raw = SAFE_CODE_PREFIX + highlighted;
      token.text = SAFE_CODE_PREFIX + highlighted;
      continue;
    }
    for (const key of ["tokens", "items"]) {
      if (Array.isArray(token[key])) {
        await replaceCodeTokens(token[key], options);
      }
    }
  }
}

async function highlightedCodeBlock(code, language, options) {
  const theme = options.theme || "github-dark";
  try {
    return await codeToHtml(code, {
      lang: language || "text",
      theme
    });
  } catch {
    const label = language ? ` data-language="${escapeHtml(language)}"` : "";
    return `<pre class="shiki fallback-code"${label}><code>${escapeHtml(code)}</code></pre>`;
  }
}

function safeRenderer() {
  const renderer = new Renderer();
  renderer.html = (token) => {
    const text = token.text || "";
    if (text.startsWith(SAFE_CODE_PREFIX)) {
      return text.slice(SAFE_CODE_PREFIX.length);
    }
    return escapeHtml(token.raw || text);
  };
  renderer.link = (token) => {
    const href = String(token.href || "").trim();
    const text = token.text || href;
    if (!/^(https?:|mailto:)/i.test(href)) {
      return escapeHtml(text);
    }
    const title = token.title ? ` title="${escapeHtml(token.title)}"` : "";
    return `<a href="${escapeHtml(href)}"${title} target="_blank" rel="noreferrer noopener">${text}</a>`;
  };
  renderer.image = (token) => {
    const href = String(token.href || "").trim();
    if (!/^https?:/i.test(href)) return escapeHtml(token.text || "");
    const alt = escapeHtml(token.text || "");
    const title = token.title ? ` title="${escapeHtml(token.title)}"` : "";
    return `<img src="${escapeHtml(href)}" alt="${alt}"${title}>`;
  };
  return renderer;
}

function htmlDocument(body, options = {}) {
  const bodyClass = options.kind === "code" ? "markdown-body code-document" : "markdown-body";
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  color-scheme: light dark;
  --bg: transparent;
  --fg: #1c1c1e;
  --muted: #8e8e93;
  --border: rgba(0,0,0,0.15);
  --panel: rgba(0,0,0,0.04);
  --panel-strong: rgba(0,0,0,0.08);
  --link: #007aff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --fg: #e7e7e7;
    --muted: #9a9a9a;
    --border: rgba(255,255,255,0.16);
    --panel: rgba(255,255,255,0.055);
    --panel-strong: rgba(255,255,255,0.095);
    --link: #7db7ff;
  }
}
html, body {
  margin: 0;
  padding: 0;
  background: var(--bg);
  color: var(--fg);
  font: -apple-system-body;
  line-height: 1.52;
}
body {
  overflow-wrap: anywhere;
}
.markdown-body {
  box-sizing: border-box;
  width: 100%;
  padding: 0;
}
.markdown-body > *:last-child {
  margin-bottom: 0 !important;
}
.code-document pre {
  margin-bottom: 0;
}
p, ul, ol, blockquote, pre, table {
  margin-top: 0;
  margin-bottom: 0.78em;
}
h1, h2, h3, h4, h5, h6 {
  margin: 1.1em 0 0.45em;
  line-height: 1.2;
  font-weight: 700;
}
h1:first-child, h2:first-child, h3:first-child {
  margin-top: 0;
}
h1 { font-size: 1.42em; }
h2 { font-size: 1.22em; }
h3 { font-size: 1.08em; }
a {
  color: var(--link);
  text-decoration: none;
}
a:hover { text-decoration: underline; }
img {
  display: block;
  max-width: 100%;
  height: auto;
  margin: 0.5em 0 0.9em;
  border: 1px solid var(--border);
  border-radius: 8px;
}
code:not(pre code) {
  padding: 0.12em 0.34em;
  border-radius: 5px;
  background: var(--panel-strong);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.92em;
}
pre {
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: auto;
}
pre.shiki,
pre.fallback-code {
  padding: 12px;
  background: #0d1117 !important;
  color: #e7e7e7 !important;
}
pre code {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 12.5px;
}
blockquote {
  border-left: 3px solid var(--border);
  color: var(--muted);
  margin-left: 0;
  padding-left: 12px;
}
table {
  border-collapse: collapse;
  display: block;
  overflow-x: auto;
  border: 1px solid var(--border);
  border-radius: 8px;
}
th, td {
  border: 1px solid var(--border);
  padding: 6px 9px;
  text-align: left;
  vertical-align: top;
}
th {
  background: var(--panel-strong);
  font-weight: 650;
}
td {
  background: var(--panel);
}
hr {
  border: 0;
  border-top: 1px solid var(--border);
  margin: 1em 0;
}
</style>
</head>
<body><main class="${bodyClass}">${body}</main></body>
</html>`;
}

function normalizeLanguage(language) {
  const raw = String(language || "").trim().toLowerCase().split(/\s+/)[0] || "text";
  return LANGUAGE_ALIASES.get(raw) || raw;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
