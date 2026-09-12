// Pure-function tests for digest.js. Run: node App/brainmaxxing/Resources/DigestWeb/dev/test-helpers.mjs
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const h = require('../digest.js');
const markdownit = require('../vendor/markdown-it/markdown-it.min.js');
const md = markdownit({ html: false, linkify: true, typographer: false });
const ids = new Set(['2610.24343', '2610.28537']);
let n = 0;
const test = async (name, fn) => { await fn(); n++; console.log('ok', name); };

await test('citations: in-digest -> anchor, other -> arXiv, existing links untouched', () => {
  assert.equal(h.linkCitations('see [2610.24343] and [2510.00001v2]', ids),
    'see [2610.24343](#paper-2610.24343) and [2510.00001](https://arxiv.org/abs/2510.00001)');
  assert.equal(h.linkCitations('[2610.24343](https://x)', ids), '[2610.24343](https://x)');
});

await test('OpenAlex citations: in-digest -> anchor, other -> left as written', () => {
  const oa = new Set(['W4381712656', '2610.24343']);
  assert.equal(h.linkCitations('[W4381712656] vs [W1] and [2610.24343v3]', oa),
    '[W4381712656](#paper-W4381712656) vs [W1] and [2610.24343](#paper-2610.24343)');
  assert.equal(h.linkCitations('[W4381712656](https://x) [w123] [W12a]', oa), '[W4381712656](https://x) [w123] [W12a]');
});

await test('abs button label: arXiv abs, DOI, OpenAlex', () => {
  assert.equal(h.absLabel('https://arxiv.org/abs/2610.24343v1'), 'abs');
  assert.equal(h.absLabel('https://doi.org/10.1016/j.neunet.2026.107812'), 'DOI');
  assert.equal(h.absLabel('https://openalex.org/W4381712656'), 'OpenAlex');
});

await test('HF item: title and upvotes when present, old line otherwise, escaped', () => {
  const full = h.hfItemHtml(md, { id: '2610.26203', one_line: 'see [2610.24343]', title: 'A <b>T</b>', upvotes: 226 }, ids);
  assert.match(full, /^<a href="https:\/\/arxiv.org\/abs\/2610.26203">2610.26203<\/a> <strong>A &lt;b&gt;T&lt;\/b&gt;<\/strong>, <span class="upvotes">226 upvotes<\/span> - see <a href="#paper-2610.24343">/);
  assert.equal(h.hfItemHtml(md, { id: '2610.26203', one_line: 'x' }, ids),
    '<a href="https://arxiv.org/abs/2610.26203">2610.26203</a> x');
  assert.match(h.hfItemHtml(md, { id: '2610.26203', one_line: 'x', upvotes: 0 }, ids), /<\/a> <span class="upvotes">0 upvotes<\/span> - x$/);
});

await test('math is protected from markdown and restored with delimiters', () => {
  const html = h.renderMarkdown(md, 'Loss $a_i * b_j$ and $$\\sum_{k} x_k^*$$ cost $5 or $10.', ids);
  assert.match(html, /\$a_i \* b_j\$/);
  assert.match(html, /\$\$\\sum_\{k\} x_k\^\*\$\$/);
  assert.doesNotMatch(html, /<em>/);
  assert.match(html, /cost \$5 or \$10/);
});

await test('markdown renders, raw HTML is escaped, citation becomes a link', () => {
  const html = h.renderMarkdown(md, '**bold** <script>x</script> [2610.24343]', ids);
  assert.match(html, /<strong>bold<\/strong>/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /<a href="#paper-2610.24343">2610.24343<\/a>/);
});

await test('mermaid source strips a stray fence', () => {
  assert.equal(h.mermaidSource('```mermaid\nflowchart LR\n  A --> B\n```'), 'flowchart LR\n  A --> B');
  assert.equal(h.mermaidSource('  flowchart LR\n A-->B  '), 'flowchart LR\n A-->B');
  assert.equal(h.mermaidSource(''), '');
});

await test('mermaid: ok -> svg; parse error -> raw block, never blank', async () => {
  const good = { parse: async () => true, render: async () => ({ svg: '<svg id="x"></svg>' }) };
  const bad = { parse: async () => { throw new Error('Parse error on line 2:\n...'); }, render: async () => ({ svg: '' }) };
  const ok = await h.mermaidHtml('flowchart LR\nA-->B', good, 'm1');
  assert.equal(ok.ok, true);
  assert.match(ok.html, /<svg/);
  const err = await h.mermaidHtml('flowchart TD\n  A[x] --> B{<y', bad, 'm2');
  assert.equal(err.ok, false);
  assert.match(err.html, /<pre class="mermaid-error">flowchart TD\n  A\[x\] --&gt; B\{&lt;y<\/pre>/);
  assert.match(err.html, /Parse error on line 2/);
  const missing = await h.mermaidHtml('flowchart LR\nA-->B', undefined, 'm3');
  assert.equal(missing.ok, false);
  assert.match(missing.html, /mermaid-error/);
  assert.deepEqual(await h.mermaidHtml('   ', bad, 'm4'), { ok: true, html: '' });
});

await test('authors line caps at six', () => {
  assert.equal(h.authorsLine(['a', 'b']), 'a, b');
  assert.equal(h.authorsLine(['1', '2', '3', '4', '5', '6', '7']), '1, 2, 3, 4, 5, 6 et al.');
});

await test('sample fixture: every text field renders and every citation resolves', () => {
  const d = JSON.parse(readFileSync(new URL('./sample-digest.json', import.meta.url), 'utf8'));
  const all = new Set(d.papers.map((p) => p.id));
  for (const c of d.clusters) for (const id of c.paper_ids) assert.ok(all.has(id), id);
  for (const p of d.papers) for (const f of ['essence', 'detail', 'why_it_matters', 'caveats']) h.renderMarkdown(md, p[f], all);
  const html = h.renderMarkdown(md, d.clusters[0].narrative, all);
  assert.match(html, /href="#paper-2610.24343"/);
  assert.match(html, /href="https:\/\/arxiv.org\/abs\/2510.00001"/);
  assert.match(html, /href="#paper-W4381712656"/);
  assert.match(html, /\[W1000000001\]/);
  const oa = d.papers.find((p) => p.id.startsWith('W'));
  assert.ok(oa && oa.venue && !oa.links.html, 'fixture has an OpenAlex paper with venue, no HTML link');
  assert.ok(d.hf_section.some((e) => e.title && typeof e.upvotes === 'number') && d.hf_section.some((e) => !e.title));
  for (const e of d.hf_section) h.hfItemHtml(md, e, all);
});

console.log(`${n} passed`);
