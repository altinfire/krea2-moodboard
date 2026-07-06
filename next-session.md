# Next session: ship design D as the index, remove the POCs

Working dir: `~/projects/krea2-moodboard` (own repo, public, published anonymously as
`altinfire` — local git config already set; keep the noreply email on commits). The live
site is GitHub Pages from `main` root: **pushing a rebuilt `index.html` publishes
immediately** — verify locally before pushing.

Read first: `backlog.md`, `adr-001-index-redesign.md` (what was proposed/selected),
`taxonomy-mood.md` (register vocabulary + method). The ComfyOps repo's CLAUDE.md has the
project conventions; this repo's README documents the build pipeline.

## State as of 2026-07-06 (all committed unless noted)

- **`design-d.template.html`** — the accepted design (ADR-001), full HTML/CSS/JS with
  `__DATA__` (minified catalog JSON array) and `__COUNT__` ("3,549") placeholders. It
  already has: doctype + `<html lang>`, no staff picks, no `content-visibility` (see
  freeze bug below), the two-level mood index, `moodDetail` filter logic. It does NOT yet
  have meta description / OG / Twitter tags / favicon — add those during the port.
- **`krea2-moodboard-mood-registers.json`** — pass-2 records for all 1,539 noir/ethereal
  boards: `{slug, mood, moodDetail|null, source: consensus|arbiter, pass: 2}` plus
  `prevMood` on the 80 boards whose top-level mood was corrected. Pass-1 files
  (`krea2-moodboard-facets.json`, `krea2-moodboards.json`) are still untouched.
- **`classify-mood-registers.ps1`** — the usage-gated pass-2 classifier (resumable;
  re-runs skip classified slugs; gates on `node ~/.claude/check-usage.js` at 80% of the
  5-hour window).
- **Untracked POC files to delete at the end**: `design-a-index.html`,
  `design-b-lighttable.html`, `design-c-promptline.html`, `design-d-hybrid.html`.

## Tasks (in order)

1. **Port D into `build-moodboard-catalog.ps1` §4** — replace the `$html = @'...'@`
   template with `design-d.template.html`'s content. The build does `.Replace()` on
   `__COUNT__` / `__STAFF__` / `__DATA__` / `__BUILDDATE__`; D uses only `__COUNT__` and
   `__DATA__` — drop `__STAFF__`, wire `__BUILDDATE__` into D's rail footer. While in
   there, add the missing head metadata (meta description, `og:title/description/image`
   — `screenshot.png` — `og:url`, `twitter:card summary_large_image`, inline-SVG favicon).
2. **Data-side changes in §2 of the build script**:
   - Remove `staffPick` (three touchpoints listed in the backlog item).
   - Add a second left-join by slug against `krea2-moodboard-mood-registers.json`:
     override `facets.mood` with the pass-2 value (80 corrections) and add
     `facets.moodDetail` (null when no record). Keep the registers file separate rather
     than rewriting the facets file — it preserves provenance and the classifier's
     append/resume model. Bump `ConvertTo-Json -Depth` if needed (facets gains a field).
3. **Rebuild** with `./build-moodboard-catalog.ps1 -SkipImages` (catalog shape changed, so
   `-HtmlOnly` is not enough; the crawl re-runs in ~1 min). If the crawl finds NEW boards:
   run `./classify-new-boards.ps1` (pass-1 facets), then `./classify-mood-registers.ps1`
   (pass-2 for any new noir/ethereal boards), then rebuild again.
4. **Verify locally** (serve: any `python -m http.server 8123` from the repo root, e.g.
   the ComfyUI venv python; `file://` also works):
   - `<!doctype html>` is the first line of `index.html`; `grep -ci staffpick` → 0.
   - Rail: two-level mood index renders; per-facet counts sum to 3,549.
   - **Freeze regression (mandatory)**: filter mood=noir, fling-scroll 30+ wheel ticks —
     the tab must not lock. Root cause was `content-visibility: auto;
     contain-intrinsic-size: auto 350px` on `.card` (permanent Chromium layout loop —
     full causal tests in backlog). D's template omits it; make sure the port keeps it
     out. Never reintroduce cv — if Show-all layout cost ever matters, use windowing.
   - Smoke: search `/`, shuffle, favorites heart, pill → tray → Copy, lightbox arrows,
     narrow-window layout (rail collapses to chip rows under 980px).
5. **README updates**: rewrite "Using it" for the rail UI (no dropdowns, no staff-picks
   checkbox, registers exist); files table (+ registers JSON, + classify-mood-registers,
   + adr/backlog/taxonomy docs); Facet classification section gains a pass-2 paragraph
   (link `taxonomy-mood.md`); drop staff-pick mentions (lines 21, 74; line 43 documents
   the API field — keep); fix bundled-image size ~253 MB → ~297 MB (backlog item 3).
6. **Retake `screenshot.png`** at ~1440px width (it's also the og:image).
7. **Cleanup**: delete the four `design-*.html` POCs and `design-d.template.html` (the
   build script owns the template after the port); delete `next-session.md` (this file);
   check off completed backlog items (leave the mood item's "extend to surreal" note).
8. **Commit + push** — push publishes; eyeball the built page one last time first. Also
   sanity-check the Pages URL after push.
9. **ComfyOps side (optional, separate commit there)**: `.claude/skills/enhance-krea2/`
   documents the catalog schema — `moodDetail` is additive and worth a mention as a
   sharper style-matching key.

## Gotchas / hard-won facts

- The build inlines data with `-replace '</','<\/'` before `.Replace('__DATA__', ...)` —
  keep that escaping or an inline `</script>` in a profile breaks the page.
- 80 mood corrections mean facet counts differ from pass-1: noir 721→705,
  ethereal-dreamy 818→783, and small gains for gritty-industrial (+14),
  minimalist-serene (+17), surreal (+11), etc. Register slice sizes:
  noir → chiaroscuro 206 / nocturnal 100 / spectral 97 / glitch 61 / luminous 60 /
  minimal 54 / kinetic 40 / liminal 26 / null 61; ethereal → luminous 200 / painterly 97
  / nocturnal 93 / kinetic 92 / spectral 57 / twilight 57 / minimal 37 / liminal 34 /
  null 116.
- Register semantics: one shared support-gated vocabulary; allowlists per mood (only
  noir + ethereal-dreamy so far); null = plain member of the mood, normal and expected;
  "cinematic" deliberately NOT a register (ADR of that call in `taxonomy-mood.md` open
  questions — resolved as: drop generic, keep chiaroscuro, park cross-mood blends).
- Extending to `surreal` (533): run the phase-1 frequency analysis for that bucket first
  (see `taxonomy-mood.md` for the method) to pick its allowlist, add it to `$ALLOW` in
  `classify-mood-registers.ps1`, re-run — ~11 batches, cheap (Haiku barely moves the
  usage window; the full 31-batch run cost ~25% of a 5-hour window minus session
  overhead).
- Usage discipline: check `node ~/.claude/check-usage.js`; at 100% the session dies
  without regard to in-flight state. Batch expensive work; commit checkpoints early.
- Chrome-automation screenshots race page init on these 3.6 MB pages — wait ≥5s after
  navigation before clicking rail rows, and coordinate clicks silently miss if the JS
  hasn't bound yet (verify state changed before trusting a click).
- git warns LF→CRLF on the md files — harmless.
