# brainmaxxing

A macOS app that reads the new arXiv papers in my areas every night, ranks them against my interest profile
with Claude, and shows a readable digest of the ones worth my time the next morning.

The idea: 300 to 500 new papers a day in cs.LG, cs.AI, cs.CL, cs.CV and a few math categories is more than
anyone reads. A cheap model can filter them against a written profile, an expensive model can write a short
connected narrative about the top 15 with figures from the papers, and the result can wait in the menu bar
until 10:00.

Planned stack: Swift 6, SwiftUI, macOS 26, GRDB for storage, WKWebView for the digest body, the Anthropic
Messages API with the user's own key.

## Plan

1. `DigestCore` library: models, storage, arXiv client, triage, selection. A CLI that prints a ranked list.
2. Full text and figures, the digest writer, prompt evals on recorded days.
3. The app: sidebar, digest renderer, settings, Keychain.
4. Chat with tools, through an MCP server that other clients can use too.
5. launchd agents, idle detection, menu bar, notifications.
6. OpenAlex and HuggingFace Daily Papers as extra sources, feedback into triage.
7. Polish for other users: onboarding, updates, notarization.

## Build

```
swift build
swift test
```
