# ADR-001: Adopt the index-rail redesign (design D)

Date: 2026-07-06 · Status: **accepted, implemented 2026-07-06** (ported into `build-moodboard-catalog.ps1` §4)

## Context

The original controls read as "form-soup": no action hierarchy (Shuffle, the primary joy
verb, styled identically to the Show-all escape hatch), four native `<select>`s hiding the
curated facet vocabulary — the best content on the page — behind OS dropdowns, filter
state that barely registered visually, and controls that scrolled away on a page built
for deep scrolling. Four full-catalog working prototypes were built and reviewed live.

## Options considered

- **A · The Index** — the taxonomy *is* the navigation: a sticky left rail rendered as a
  book index (dot leaders, right-aligned mono counts), masthead and search in the rail,
  one filled-amber Shuffle in a sticky status bar. Warm lamplit palette, Palatino display.
- **B · The Light Table** — evolution of the existing identity: the prompt tray's
  floating-glass language extended to a top instrument bar (search + facet shelves that
  unfurl as chip rows), applied filters glowing like safelight chips. Georgia, current
  neutral palette.
- **C · The Prompt Line** — keyboard-first radical: one line where `mood:noir` tokens
  autocomplete (ranked, with counts) into lit chips; no filled buttons anywhere; verbs as
  mono text; cool near-black palette, mono-forward chrome.
- **D · Hybrid** — A's layout and typography with C's cooler palette (requested after
  review of A/B/C).

## Decision

**D.** The index rail keeps the facet vocabulary permanently visible and browsable — the
strongest fix for the original complaints — and the cool palette was preferred over A's
warm variant. C's token grammar is **deferred, not rejected**: with only ~35 top-level
facet values it under-delivered; now that mood registers exist (see `taxonomy-mood.md`),
the rail's search box is the natural future host for `mood:noir/liminal`-style tokens.
B's twin-instrument concept is archived here in case the design evolves.

## Consequences

- Porting D into the build script closes several backlog items in one rebuild: the
  quirks-mode doctype fix, staff-picks removal, and the content-visibility renderer
  hard-freeze fix (a pre-existing production bug discovered during prototype stress
  testing — see the HIGH backlog item for the repro and causal tests).
- The pass-2 mood registers render as indented sub-entries under noir and ethereal-dreamy
  in the rail; the 80 pass-2 mood corrections ship with the same rebuild.
- Social/OG metadata is still missing from the D template and must be added at port time.
- localStorage keys (`krea-mb-favs`, `krea-mb-tray`) are unchanged, so existing visitors
  keep their favorites and tray across the redesign.
