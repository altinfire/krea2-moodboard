# Mood taxonomy refinement — working notes

Phase 1 output (2026-07-06): sub-vocabulary derivation for the fat mood buckets, grounded
in per-bucket frequency analysis of titles and keywords. No classification has run yet —
this doc is the review checkpoint before spending on the pass-2 sweep.

## Actual mood distribution (n = 3,549)

ethereal-dreamy 818 · noir 721 · surreal 533 · nostalgic-retro 384 · minimalist-serene 303
· vibrant-energetic 300 · gritty-industrial 158 · cozy-folk 112 · cosmic-mystical 111 ·
gothic-dark 109

Phase-1 scope: **noir + ethereal-dreamy** (43% of catalog). `surreal` (533) is the obvious
third; `nostalgic-retro` (384) borderline. Everything ≤303 discriminates fine as-is.

## Key design finding: one shared register vocabulary

The same subfamily words recur in *both* fat buckets (title-word counts, noir / ethereal):
nocturnal 93+18 / 116+23 · spectral 98 / 55 · kinetic+motion 55 / 99 · minimal* 31 / 54 ·
luminous 29 / 160. So `moodDetail` should be **one shared register list**, not per-mood
enums — each mood simply allows the registers with real support in its bucket. Rail UI
indents only the registers that exist under each mood (with counts); token grammar
composes as `mood:noir/kinetic` and `mood:ethereal-dreamy/kinetic`.

## Proposed registers (support-gated at ~25 boards)

| register | noir evidence | ethereal evidence | notes |
|---|---|---|---|
| nocturnal | title 93+18 nocturne | title 116+23 | night scenes; not expressible via other facets |
| spectral | title 98 (+abyssal 8) | title 55 | ghostly/apparition register |
| kinetic | title kinetic 35 + motion 20; kw motion blur 53, shutter drag 23 | title 43+56; kw ICM 37, long-exposure 28, shutter drag 22 | motion techniques; orthogonal to subject figure-motion (only 18/50 overlap) |
| luminous | title 29 (borderline) | title 127 + luminescen* 33; kw bioluminescent glow 25 | glow register; ethereal-strong, noir-marginal |
| minimal | title minimalism 22 + minimalist 9 + graphic 25 + brutalist 9; kw minimalist composition 35, stark silhouette 19 | title 54 | stark/graphic register; distinct from mood minimalist-serene (that's a different *family*, this is a register within one) |
| glitch | title 38 + cyber 11 + cybernetic 8; kw pixel sorting 19, chromatic aberration 37 | title 15 (below gate) | digital-corruption register; noir-only for now |
| chiaroscuro | title 79; kw chiaroscuro lighting 197 | title 15 | the "classic studio noir" register — see open questions |
| liminal | title 9 but kw liminal space 22 | kw liminal space 20 | marginal on the gate; kw evidence carries it |
| twilight | — | title 37 | dusk/blue-hour; ethereal-only |
| painterly | — | title impressionism 34 + impressionist 13; kw painterly texture 20 | style register; NOT medium=painting (many are film-photography with painterly blur) |

Boards matching no register keep `moodDetail: null` — plain noir / plain ethereal is a
valid, expected majority-ish outcome. Estimated register coverage: roughly half to
two-thirds of each bucket.

## Dropped candidates (orthogonality — already expressible by cross-filtering)

| candidate | count | restates |
|---|---|---|
| monochrome/monochromatic (noir 90+30, eth 40) | | palette:monochrome (304 of noir already) |
| crimson 62 / cobalt 27+21 / amber 22+22 / neon 20 / cyan 10+17 / pastel 27 / prismatic 22 | | palette values |
| analog 50/50, grain 28, blur 24, haze 23 | | medium film-photography + universal texture kws |
| urban 15 | | subject:urban |
| pastoral 20 + botanical 13 | | subject:nature-botanical |
| noir-in-ethereal 66, surrealism-in-ethereal 41, nostalgia 33 | | cross-mood blends — a different feature (see open questions) |
| thermal 13, macro 15, melancholy 12, solitude 12, surveillance (<8) | | below support gate — n.b. "surveillance noir" looked real anecdotally and failed the count; anecdotes lose |

## Open questions for review

1. **cinematic (noir title 231)** — the single biggest noir modifier. Register or generic
   default? Lean: drop as generic (it's noir's ambient register; a `cinematic` sub would
   be a 30% catch-all with fuzzy edges). Decide before prompting.
2. **chiaroscuro** — kw appears on 197 noir boards (near-universal device). As a register
   it means "title-flagged classic studio noir" (~80). Keep or fold into null? Lean keep.
3. **Cross-mood blends** (Ethereal Noir 66, Ethereal Surrealism 41): these are boards
   where the title-first rule picked one family. A `moodBlend` second value could express
   them, but that's a third axis — park it unless review says otherwise.
4. Extend to `surreal` (533) in the same pass, or ship two buckets first? Lean: two first,
   validate, extend.

## Phase 2 — classification run plan (usage-gated)

- Generalize `classify-new-boards.ps1` into a scoped re-pass: `-Facet moodDetail
  -Slugs <bucket>` with the register list + per-register definitions in the prompt
  (enum-constrained, `null` allowed and expected), dual Haiku vote + Sonnet arbiter,
  provenance `pass: 2`, **append after every batch** (a hard stop loses ≤1 batch of 50).
- Also have pass 2 re-emit its implied top-level mood; disagreements with pass 1 go to
  the arbiter with both labels — this is the accuracy pass (mood was 82% single-run
  agreement pre-tie-break).
- Scope: 1,539 boards ≈ 31 batches. Original 3,549-board run ≈ 8.4M subagent tokens, so
  estimate ~3.7M (mostly Haiku) — but the binding constraint is the account usage window,
  not dollars.
- **Usage gate between batches**: run `node ~/.claude/check-usage.js`; stop launching new
  batches when the 5-hour window exceeds ~80% (leave margin — the session dies at 100%
  without regard to in-flight state). Re-running skips already-classified slugs, so
  resume is free.
