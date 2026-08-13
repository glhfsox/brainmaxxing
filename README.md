# brainmaxxing

A macOS app that reads the new arXiv papers in your areas every night, ranks them against your interest
profile with Claude, and shows a readable digest of the ones worth your time the next morning.

Stack: Swift 6, SwiftUI, macOS 26, GRDB (SQLite + FTS5), WKWebView for the digest body, the Anthropic Messages
API (Haiku for triage, Opus for the digest). Bring your own API key.

State: the fetch, triage and select stages work from the command line. Full text, the digest writer and the app
are next.

## 1. Pipeline

### 1.1 Fetch

arXiv's Atom API is queried with `cat:cs.LG OR cat:cs.AI OR ...`, `sortBy=lastUpdatedDate`, 1000 entries per
page and at most 10 pages; hitting the page cap inside the window marks the run partial. Default categories:
`cs.LG cs.AI cs.MA cs.CL cs.CV cs.RO math.DG math.AT math.PR math.ST stat.ML`. Only papers first published inside
the window are kept; revisions of older papers are dropped unless `include_reversions` is on. All requests share
one limiter of one request per 3 seconds. HTTP 429 and 503 are retried up to three times.

The window starts `announce_lag_days` (default 4) before the start of the last complete run and is capped at
`window_cap_days` (7). arXiv serves a paper only from the announcement after its submission, so the window has
to overlap the previous one; the overlap is fetched again, but only papers without a triage score from any
earlier run are sent to triage. Raw API responses are kept per run for replay.

### 1.2 Triage (Haiku)

Batches of about 25 `(id, title, abstract, categories, authors)` go to Haiku. The system prompt is the user's
interest profile, read once per run so every batch shares the cached prefix. The output is a tool call with
`{id, score 0-10, tags, one_line}`.

Selection takes the top N (default 15) with score at least `min_score` (6) from every scored paper of the window
that has not yet been shown. Everything below the cut stays in the database with its score.

### 1.3 Cost control

Every LLM call writes `(run_id, stage, model, input, output, cache_read, cache_write, usd_estimate)`. Before a
call is sent, today's spend plus the worst case of that call (the whole prompt uncached, full `max_tokens`) must
fit under `daily_budget_usd` (default 4). When the cap is hit mid-run the run finishes with what it has and is
marked partial.

## 2. Storage

```
~/Library/Application Support/brainmaxxing/
  digest.sqlite        papers, runs, llm_calls, triage_scores; FTS5 over papers
  config.json          categories, interest profile, models, budget, schedule
  raw/<run_id>/        fetched API responses
```

The Anthropic key is kept in Keychain under the service `com.brainmaxxing.anthropic`; `ANTHROPIC_API_KEY` in
the environment wins for command-line runs. `BRAINMAXXING_HOME` overrides the data directory.

## 3. Configuration

`config.json`, all keys with their defaults (the `Config` struct is the source of truth):

```json
{
  "categories": ["cs.LG","cs.AI","cs.MA","cs.CL","cs.CV","cs.RO","math.DG","math.AT","math.PR","math.ST","stat.ML"],
  "interest_profile": "free text: what you care about, what you don't",
  "top_n": 15, "min_score": 6,
  "models": { "triage": "claude-haiku-5-5", "digest": "claude-opus-5-5", "chat": "claude-sonnet-5-5" },
  "daily_budget_usd": 4.0,
  "schedule": { "window_start": 3, "window_end": 9, "show_at": 10, "idle_minutes": 15 },
  "language": "ru", "explanation_level": "engineer",
  "window_cap_days": 7, "announce_lag_days": 4, "include_reversions": false
}
```

Prompts live in `Sources/DigestCore/Prompts/` as versioned files (`triage.v1.md`) with a JSON schema each; the
version used is recorded with every run.

## 4. Build and run

```
swift build
ANTHROPIC_API_KEY=... swift run digest-cli run --force  # a real run from the terminal
swift run digest-cli status
```

## 5. Plan

1. Done: models, storage, arXiv client, triage, selection; `digest-cli` prints a ranked list.
2. Full text and figures, the digest writer.
3. The app: sidebar, digest renderer in a web view, settings, Keychain.
4. Chat with tools, through an MCP server that other clients can use too.
5. launchd agents, idle detection, menu bar, notifications.
6. OpenAlex and HuggingFace Daily Papers as extra sources, feedback into triage.
7. Polish for other users: onboarding, updates, notarization.
