// Digest renderer for the offline WKWebView.
// Swift -> JS: window.render(digest, state), window.setState(state), window.quoteSelection().
// JS -> Swift: window.webkit.messageHandlers.digest.postMessage({type, ...}).
// The pure helpers at the top have no DOM access and are exported for node tests (dev/test-helpers.mjs).
'use strict';

(function (root) {
  // ---------- pure helpers ----------

  // `[2610.12345]` / `[2610.12345v2]` (arXiv) or `[W4381712656]` (OpenAlex).
  const CITATION = /\[(?:(\d{4}\.\d{4,5})(?:v\d+)?|(W\d+))\](?!\()/g;
  const MATH_OPEN = '';
  const MATH_CLOSE = '';

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Pulls `$$...$$`, `\[...\]`, `\(...\)` and `$...$` out of the text so markdown-it can't mangle `_` / `*` inside them.
  // Inline `$...$` must not start or end with a space and does not span a blank line; `\$` is a literal dollar.
  function protectMath(text) {
    const math = [];
    const keep = (m) => {
      math.push(m);
      return MATH_OPEN + (math.length - 1) + MATH_CLOSE;
    };
    const out = String(text)
      .replace(/\$\$[\s\S]+?\$\$/g, keep)
      .replace(/\\\[[\s\S]+?\\\]/g, keep)
      .replace(/\\\([\s\S]+?\\\)/g, keep)
      .replace(/(^|[^\\$])(\$(?!\s)(?:[^$\n\\]|\\.|\n(?!\s*\n))+?(?<!\s)\$)(?!\d)/g, (_, pre, m) => pre + keep(m));
    return { text: out, math };
  }

  // Puts the math back, HTML-escaped and with its delimiters, for KaTeX auto-render to find in the DOM.
  function restoreMath(html, math) {
    const re = new RegExp(MATH_OPEN + '(\\d+)' + MATH_CLOSE, 'g');
    return html.replace(re, (_, i) => escapeHtml(math[Number(i)] ?? ''));
  }

  // `[2610.12345]` -> a Markdown link: in-page anchor when the id is in the digest, else the arXiv abs page.
  // `[W...]` links in-page only when in the digest, else stays as written. `[id](...)` (already a link) is left alone.
  function linkCitations(text, digestIds) {
    return String(text).replace(CITATION, (m, arxiv, openalex) => {
      if (openalex) return digestIds.has(openalex) ? `[${openalex}](#paper-${openalex})` : m;
      return digestIds.has(arxiv) ? `[${arxiv}](#paper-${arxiv})` : `[${arxiv}](https://arxiv.org/abs/${arxiv})`;
    });
  }

  // Label of the paper's landing-page button: arXiv abs page, or a DOI / OpenAlex page for journal papers.
  function absLabel(url) {
    if (/^https?:\/\/(dx\.)?doi\.org\//i.test(url)) return 'DOI';
    if (/^https?:\/\/(www\.)?openalex\.org\//i.test(url)) return 'OpenAlex';
    return 'abs';
  }

  // One HF Daily Papers item as HTML: `[id] **title**, N upvotes - one_line`; title and upvotes only when present.
  function hfItemHtml(md, h, digestIds) {
    const head = [h.title ? `<strong>${escapeHtml(String(h.title).replace(/\s+/g, ' ').trim())}</strong>` : null,
      typeof h.upvotes === 'number' ? `<span class="upvotes">${h.upvotes} upvotes</span>` : null].filter(Boolean).join(', ');
    return renderMarkdown(md, `[${h.id}]`, digestIds, true) + ' ' + (head ? head + ' - ' : '') +
      renderMarkdown(md, h.one_line, digestIds, true);
  }

  // Markdown (+ math + citations) -> HTML. `md` is a markdown-it instance created with html: false.
  function renderMarkdown(md, text, digestIds, inline) {
    if (!text) return '';
    const p = protectMath(text);
    const linked = linkCitations(p.text, digestIds);
    return restoreMath(inline ? md.renderInline(linked) : md.render(linked), p.math);
  }

  // The stored value is a bare diagram body (the pipeline strips fences); strip a fence anyway, the model is not trusted.
  function mermaidSource(raw) {
    let s = String(raw || '').trim();
    const fence = s.match(/^```[ \t]*(?:mermaid)?[ \t]*\n([\s\S]*?)\n?```$/);
    if (fence) s = fence[1].trim();
    return s;
  }

  // Renders one diagram with the mermaid API. Never returns empty HTML for a non-empty source: a parse or render
  // failure yields the raw block in <pre class="mermaid-error"> with a warning line.
  async function mermaidHtml(raw, api, id) {
    const src = mermaidSource(raw);
    if (!src) return { ok: true, html: '' };
    try {
      if (!api) throw new Error('mermaid is not loaded');
      await api.parse(src);
      const out = await api.render(id, src);
      if (!out || !out.svg) throw new Error('empty render');
      return { ok: true, html: `<div class="mermaid-diagram">${out.svg}</div>` };
    } catch (e) {
      const msg = (e && (e.message || e.str)) ? String(e.message || e.str).split('\n')[0] : 'parse error';
      return {
        ok: false,
        html: `<div class="mermaid-warning">Diagram could not be rendered (${escapeHtml(msg)}). Source:</div>` +
              `<pre class="mermaid-error">${escapeHtml(src)}</pre>`,
      };
    }
  }

  function authorsLine(authors) {
    const a = authors || [];
    return a.length > 6 ? a.slice(0, 6).join(', ') + ' et al.' : a.join(', ');
  }

  const helpers = { escapeHtml, protectMath, restoreMath, linkCitations, renderMarkdown, mermaidSource,
                    mermaidHtml, authorsLine, absLabel, hfItemHtml };
  if (typeof module !== 'undefined' && module.exports) module.exports = helpers;
  if (typeof document === 'undefined') return;

  // ---------- DOM ----------

  const md = root.markdownit({ html: false, linkify: true, typographer: false });
  let current = null;            // last digest passed to render
  let state = { feedback: {}, read: [], figureBase: '' };
  let renderSeq = 0;

  function post(msg) {
    const h = root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.digest;
    if (h) h.postMessage(msg); else console.log('postMessage', JSON.stringify(msg));
  }

  function darkMode() {
    return root.matchMedia && root.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  function el(tag, cls, html) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html !== undefined) e.innerHTML = html;
    return e;
  }

  function button(label, cls, title, onClick) {
    const b = el('button', cls);
    b.type = 'button';
    b.textContent = label;
    if (title) b.title = title;
    b.addEventListener('click', onClick);
    return b;
  }

  function paperArticle(p, ids, rank) {
    const a = el('article', 'paper');
    a.id = 'paper-' + p.id;
    a.dataset.paperId = p.id;
    if (p.cluster_id) a.dataset.clusterId = p.cluster_id;

    const head = el('header', 'paper-head');
    head.appendChild(el('h3', 'paper-title', escapeHtml(p.title || p.id)));
    const meta = el('div', 'paper-meta');
    meta.innerHTML = `<span class="rank">#${rank}</span><span class="score" title="triage score">${p.score}/10</span>` +
      `<span class="pid">${escapeHtml(p.id)}</span>` +
      (p.venue ? `<span class="venue" title="journal">${escapeHtml(p.venue)}</span>` : '') +
      (p.tags || []).map((t) => `<span class="tag">${escapeHtml(t)}</span>`).join('');
    head.appendChild(meta);
    head.appendChild(el('div', 'authors', escapeHtml(authorsLine(p.authors))));

    const controls = el('div', 'controls');
    controls.appendChild(button('👍', 'fb fb-up', 'More like this', () => toggleFeedback(p.id, 1)));
    controls.appendChild(button('👎', 'fb fb-down', 'Less like this', () => toggleFeedback(p.id, -1)));
    controls.appendChild(button('Mark read', 'read-toggle', 'Toggle read', () => toggleRead(p.id)));
    const links = p.links || {};
    for (const [key, label] of [['abs', absLabel(links.abs || '')], ['html', 'HTML'], ['pdf', 'PDF']]) {
      if (links[key]) controls.appendChild(button(label, 'open', 'Open ' + label, () => post({ type: 'open', url: links[key] })));
    }
    head.appendChild(controls);
    a.appendChild(head);

    if (p.modelOmitted) a.appendChild(el('div', 'note', 'The digest writer skipped this paper; the line below is the triage summary.'));
    a.appendChild(el('div', 'essence', renderMarkdown(md, p.essence, ids)));
    if (p.why_it_matters) {
      const w = el('div', 'why');
      w.innerHTML = '<span class="label">Why it matters</span>' + renderMarkdown(md, p.why_it_matters, ids);
      a.appendChild(w);
    }
    if (p.figure && p.figure.path) {
      const f = el('figure', 'figure');
      const img = document.createElement('img');
      img.alt = 'Figure ' + p.figure.index;
      img.src = (state.figureBase || '') + p.figure.path;
      img.addEventListener('error', () => f.remove());     // a missing figure never breaks the page
      f.appendChild(img);
      f.appendChild(el('figcaption', null, renderMarkdown(md, p.figure.caption, ids, true)));
      a.appendChild(f);
    }
    if (p.detail) {
      const d = el('details', 'detail');
      d.open = true;
      d.appendChild(el('summary', null, 'Method &amp; math'));
      d.appendChild(el('div', 'detail-body', renderMarkdown(md, p.detail, ids)));
      a.appendChild(d);
    }
    if (p.mermaid && p.mermaid.trim()) {
      const m = el('div', 'mermaid-block');
      m.dataset.source = p.mermaid;
      a.appendChild(m);
    }
    if (p.caveats) {
      const c = el('div', 'caveats');
      c.innerHTML = '<span class="label">Caveats</span>' + renderMarkdown(md, p.caveats, ids);
      a.appendChild(c);
    }
    return a;
  }

  function header(d, ids) {
    const h = el('header', 'digest-head');
    h.appendChild(el('div', 'date', escapeHtml(d.date || '')));
    h.appendChild(el('h1', null, escapeHtml(d.title || '')));
    if (d.partial) h.appendChild(el('div', 'partial', 'Partial run: some stages did not finish (budget or errors). What is here is complete.'));
    h.appendChild(el('div', 'summary', renderMarkdown(md, d.summary, ids)));
    if (!d.empty) {
      const c = d.counts || {};
      const parts = [`${(d.papers || []).length} papers`, `${(d.clusters || []).length} clusters`];
      if (c.triaged) parts.push(`${c.triaged} triaged`);
      if (typeof d.costUSD === 'number') parts.push('$' + d.costUSD.toFixed(2));
      h.appendChild(el('div', 'stats', escapeHtml(parts.join(', '))));
    }
    if (d.trend_notes) {
      const t = el('div', 'trend');
      t.innerHTML = '<span class="label">Trends</span>' + renderMarkdown(md, d.trend_notes, ids);
      h.appendChild(t);
    }
    return h;
  }

  function build(d) {
    const ids = new Set((d.papers || []).map((p) => p.id));
    const rank = new Map((d.papers || []).map((p, i) => [p.id, i + 1]));
    const byId = new Map((d.papers || []).map((p) => [p.id, p]));
    const main = el('main', 'digest');
    main.appendChild(header(d, ids));
    if (d.empty) return main;

    const placed = new Set();
    for (const c of d.clusters || []) {
      const s = el('section', 'cluster');
      s.id = 'cluster-' + c.id;
      s.dataset.clusterId = c.id;
      s.appendChild(el('h2', null, escapeHtml(c.name)));
      s.appendChild(el('div', 'narrative', renderMarkdown(md, c.narrative, ids)));
      for (const pid of c.paper_ids || []) {
        const p = byId.get(pid);
        if (!p || placed.has(pid)) continue;
        placed.add(pid);
        s.appendChild(paperArticle(p, ids, rank.get(pid)));
      }
      main.appendChild(s);
    }
    const rest = (d.papers || []).filter((p) => !placed.has(p.id));
    if (rest.length) {
      const s = el('section', 'cluster unclustered');
      s.appendChild(el('h2', null, (d.clusters || []).length ? 'Other papers' : 'Papers'));
      for (const p of rest) s.appendChild(paperArticle(p, ids, rank.get(p.id)));
      main.appendChild(s);
    }
    if ((d.hf_section || []).length) {
      const s = el('section', 'hf');
      s.appendChild(el('h2', null, 'What the community is discussing'));
      const ul = el('ul');
      for (const h of d.hf_section) {
        ul.appendChild(el('li', null, hfItemHtml(md, h, ids)));
      }
      s.appendChild(ul);
      main.appendChild(s);
    }
    const foot = el('footer', 'digest-foot');
    foot.textContent = [d.model, d.promptVersion ? 'prompt v' + d.promptVersion : null,
      d.generatedAt ? 'generated ' + new Date(d.generatedAt).toLocaleString() : null].filter(Boolean).join(' / ');
    main.appendChild(foot);
    return main;
  }

  async function renderDiagrams(container, seq) {
    const api = root.mermaid;
    if (api) api.initialize({ startOnLoad: false, securityLevel: 'strict', theme: darkMode() ? 'dark' : 'default' });
    let n = 0;
    for (const block of container.querySelectorAll('.mermaid-block')) {
      if (seq !== renderSeq) return;            // a newer render started
      const id = `mmd-${seq}-${n++}`;
      const out = await mermaidHtml(block.dataset.source, api, id);
      // mermaid leaves its scratch element (and an error SVG) in <body> when render throws.
      for (const stray of [document.getElementById(id), document.getElementById('d' + id)]) if (stray) stray.remove();
      block.innerHTML = out.html;
    }
  }

  function applyState() {
    const fb = state.feedback || {};
    const read = new Set(state.read || []);
    for (const a of document.querySelectorAll('article.paper')) {
      const id = a.dataset.paperId;
      a.querySelector('.fb-up').classList.toggle('on', fb[id] === 1);
      a.querySelector('.fb-down').classList.toggle('on', fb[id] === -1);
      const isRead = read.has(id);
      a.classList.toggle('is-read', isRead);
      a.querySelector('.read-toggle').textContent = isRead ? 'Marked read' : 'Mark read';
    }
  }

  function toggleFeedback(id, verdict) {
    const now = (state.feedback || {})[id];
    const next = now === verdict ? 0 : verdict;
    state.feedback = Object.assign({}, state.feedback);
    if (next === 0) delete state.feedback[id]; else state.feedback[id] = next;
    applyState();                               // optimistic; Swift re-sends the stored state via setState
    post({ type: 'feedback', paperId: id, verdict: next });
  }

  function toggleRead(id) {
    const read = new Set(state.read || []);
    const next = !read.has(id);
    if (next) read.add(id); else read.delete(id);
    state.read = Array.from(read);
    applyState();
    post({ type: 'read', paperId: id, read: next });
  }

  function render(digest, newState) {
    current = digest;
    if (newState) state = Object.assign({ feedback: {}, read: [], figureBase: '' }, newState);
    const seq = ++renderSeq;
    const root_ = document.getElementById('root');
    root_.replaceChildren(build(digest));
    if (root.renderMathInElement) {
      root.renderMathInElement(root_, {
        delimiters: [
          { left: '$$', right: '$$', display: true },
          { left: '\\[', right: '\\]', display: true },
          { left: '\\(', right: '\\)', display: false },
          { left: '$', right: '$', display: false },
        ],
        throwOnError: false,
      });
    }
    applyState();
    hideAsk();
    return renderDiagrams(root_, seq);
  }

  function setState(newState) {
    state = Object.assign({}, state, newState || {});
    applyState();
  }

  // ---------- selection -> quote ----------

  const ask = el('button', 'ask-button');
  ask.type = 'button';
  ask.textContent = 'Ask about this';
  ask.title = 'Quote the selection in the chat (⌘⇧L)';
  ask.addEventListener('mousedown', (e) => e.preventDefault());    // keep the selection
  ask.addEventListener('click', () => quoteSelection());

  function selectionContext() {
    const sel = root.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
    const text = sel.toString().replace(/\s+\n/g, '\n').trim();
    if (!text) return null;
    const range = sel.getRangeAt(0);
    let node = range.commonAncestorContainer;
    if (node.nodeType !== 1) node = node.parentElement;
    if (!node || !node.closest('#root')) return null;
    const paper = node.closest('[data-paper-id]');
    const cluster = node.closest('[data-cluster-id]');
    // Outside a paper card (e.g. a cluster narrative): attribute the quote to the first paper cited in the selection.
    const cite = paper ? null : Array.from(node.querySelectorAll('a[href^="#paper-"]')).find((a) => range.intersectsNode(a));
    const paperId = paper ? paper.dataset.paperId : (cite ? cite.getAttribute('href').slice('#paper-'.length) : null);
    const clusterId = paper ? (paper.dataset.clusterId || null) : (cluster ? cluster.dataset.clusterId : null);
    return { text, paperId, clusterId, rect: range.getBoundingClientRect() };
  }

  function hideAsk() { ask.style.display = 'none'; }

  function updateAsk() {
    const ctx = selectionContext();
    if (!ctx) return hideAsk();
    ask.style.display = 'block';
    const top = root.scrollY + ctx.rect.bottom + 6;
    const left = Math.min(root.scrollX + ctx.rect.right - ask.offsetWidth, root.scrollX + document.documentElement.clientWidth - ask.offsetWidth - 8);
    ask.style.top = top + 'px';
    ask.style.left = Math.max(8, left) + 'px';
  }

  // Posts the current selection as a quote; returns false when nothing quotable is selected. Called by Cmd-Shift-L in Swift.
  function quoteSelection() {
    const ctx = selectionContext();
    if (!ctx) return false;
    const msg = { type: 'quote', paperId: ctx.paperId, text: ctx.text };
    if (ctx.clusterId) msg.clusterId = ctx.clusterId;
    post(msg);
    root.getSelection().removeAllRanges();
    hideAsk();
    return true;
  }

  let selTimer = null;
  document.addEventListener('selectionchange', () => {
    clearTimeout(selTimer);
    selTimer = setTimeout(updateAsk, 120);
  });

  // External links go to the default browser through Swift; in-page anchors scroll.
  document.addEventListener('click', (e) => {
    const a = e.target.closest && e.target.closest('a[href]');
    if (!a) return;
    const href = a.getAttribute('href');
    if (href.startsWith('#')) {
      e.preventDefault();
      const target = document.getElementById(href.slice(1));
      if (target) {
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        target.classList.add('flash');
        setTimeout(() => target.classList.remove('flash'), 1200);
      }
      return;
    }
    e.preventDefault();
    if (/^https?:/i.test(href)) post({ type: 'open', url: href });
  });

  if (root.matchMedia) {
    root.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (current) render(current); });
  }

  document.addEventListener('DOMContentLoaded', () => {
    hideAsk();
    document.body.appendChild(ask);
  });

  root.render = render;
  root.setState = setState;
  root.quoteSelection = quoteSelection;
})(typeof window !== 'undefined' ? window : globalThis);
