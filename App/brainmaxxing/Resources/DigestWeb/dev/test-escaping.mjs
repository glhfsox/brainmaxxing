// Escaping tests for model-written text in digest.js. Run: node App/brainmaxxing/Resources/DigestWeb/dev/test-escaping.mjs
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const h = require('../digest.js');
const markdownit = require('../vendor/markdown-it/markdown-it.min.js');
const md = markdownit({ html: false, linkify: true, typographer: false });
const ids = new Set(['2610.24343']);
let n = 0;
const test = (name, fn) => { fn(); n++; console.log('ok', name); };
const testAsync = async (name, fn) => { await fn(); n++; console.log('ok', name); };

// No element with an event handler, no script, no javascript:/file:/data: href or src may come out of model text.
// Checked on real tags only (escaped text like `&lt;img onerror=...&gt;` is harmless).
const badTag = /^<(script|iframe|object|embed|img|svg|style)\b|\son\w+\s*=|href="\s*(javascript|vbscript|file|data):|\ssrc=/i;
const unsafe = { test: (html) => (html.match(/<[a-z][^>]*>/gi) || []).some((t) => badTag.test(t)) };
const assertSafe = (html, msg) => assert.ok(!unsafe.test(html), msg || html);

const vectors = [
  '<img src=x onerror=alert(1)>',
  '[x](javascript:alert(1))',
  '[x](JaVaScRiPt:alert(1))',
  '[x](file:///etc/passwd)',
  '![x](file:///Users/me/Library/Application%20Support/brainmaxxing/digest.sqlite)',
  '[x](data:text/html,<script>alert(1)</script>)',
  '$</span><img src=x onerror=alert(1)>$',
  '$$"><svg onload=alert(1)>$$',
  '[a]($x" onmouseover="alert(1)$)',
  '\\(<script>alert(1)</script>\\)',
  '\uE0000\uE001 and \uE000999\uE001 <b onclick=1>',
  '[2610.24343"><img src=x onerror=1>]',
  'see https://evil.example/"onmouseover="alert(1)',
];

test('model text never yields active HTML (block and inline)', () => {
  for (const v of vectors) {
    for (const inline of [false, true]) {
      const html = h.renderMarkdown(md, v, ids, inline);
      assertSafe(html, `${JSON.stringify(v)} -> ${html}`);
    }
  }
});

test('remote markdown images are emitted: only the WKContentRuleList (file: only) keeps the page offline', () => {
  assert.match(h.renderMarkdown(md, '![x](https://evil.example/p.png)', ids), /<img src="https:\/\/evil\.example\/p\.png"/);
});

test('escapeHtml covers the five characters', () => {
  assert.equal(h.escapeHtml(`<a href="x" title='y'>&</a>`), '&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;');
});

await testAsync('mermaid error block escapes the source and the parser message', async () => {
  const bad = { parse: async () => { throw new Error('<img src=x onerror=1>'); }, render: async () => ({}) };
  const out = await h.mermaidHtml('flowchart LR\n A["<script>alert(1)</script>"]', bad, 'm');
  assertSafe(out.html);
});

console.log(`${n} passed`);
