# Golden day 2026-10-21

Exported from run `20261021-232305-2f65` with `digest-cli record-golden`, then shrunk so a
triage eval costs cents instead of dollars.

**The scores in `triage_golden.json` are model scores (triage v1, Haiku), not the user's judgement.** They become
golden only once the user has gone through them and edited what they disagree with. Until then, "MAE vs golden"
measures drift from triage v1, not accuracy.

Subset: the full run triaged 2464 papers. Kept: all 128 papers with score >= 7, plus 122 of the remaining 2336
drawn with `random.Random(20261021).sample` over the id-sorted list, 250 in total. `papers.json` and
`triage_golden.json` hold the same 250 ids in the same (id ascending) order. Score histogram of the subset:
0:4 1:36 2:32 3:20 4:18 5:5 6:7 7:103 8:24 9:1.

`config.json` is the config at export time (`language: ru`, `top_n: 15`, `min_score: 6`).
`selected.json` is the run's top 15 (all in the subset). `fulltext/` and `figures.json` are empty and there is
no `digest_golden.json`: this run stopped at `select`, so the day is usable for the triage eval only.

Edit scores in place. Do not re-run `record-golden` into this directory: it keeps the existing
`triage_golden.json` but rewrites `papers.json` with all 2464 papers, and the two files stop matching.
