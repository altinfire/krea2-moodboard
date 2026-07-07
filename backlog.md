# Backlog

Pre-announce polish. `index.html` and `krea2-moodboards.json` are generated — every fix
lands in `build-moodboard-catalog.ps1` (or README) and gets rebuilt, never hand-edited.

- [x] **HIGH: fix renderer hard-freeze — remove `content-visibility: auto` from `.card`.**
  *Done 2026-07-06 with the design-D port: the shipped template has no `content-visibility`;
  re-verified post-rebuild (mood=noir 60-tick fling + Show-all 40-tick fling, no freeze).
  Never reintroduce cv — if Show-all layout cost ever matters, use windowing.*
  Repro (verified 2026-07-06, Chrome on Windows): filter to mood=noir (721 boards),
  fling-scroll → the tab hard-freezes in a layout loop. No recovery after 2+ minutes, no
  network activity, and the renderer process keeps burning a full core even after the tab
  is closed. Reproduced on the shipped `index.html`, not just prototypes.
  Cause isolated by A/B tests: `content-visibility: auto; contain-intrinsic-size: auto
  350px` on `.card` (§4 of the build script). The 350px estimate is ~30% below real card
  heights and Chromium's estimate-swap thrashes into a permanent loop on fast scrolls
  through large filtered views. Tested alternatives: `overflow-anchor: none` — still
  freezes; fixed `contain-intrinsic-size: 480px 500px` — still stalls; **removing the two
  declarations entirely — survives worst-case (Show all + 40-tick fling), recovers from
  stalls**. Cost of removal: one-time full layout on Show-all (seconds); freeze is worse.
  Fix in the build script template, rebuild with `-HtmlOnly`, re-run the fling-scroll
  repro before closing. (Already applied to the three `design-*.html` prototypes.)

- [x] **Fix quirks mode: add a proper document skeleton to the HTML template.**
  *Done 2026-07-06 (design-D port): `<!doctype html>` + `<html lang="en">`;
  `document.compatMode` verified `CSS1Compat`.*
  The template in `build-moodboard-catalog.ps1` starts at `<meta charset>` with no
  `<!doctype html>`, so browsers render the page in quirks mode and the layout works by
  accident. Add `<!doctype html>` + `<html lang="en">`, then rebuild with `-HtmlOnly` and
  eyeball the layout — quirks mode changes box-model/line-height behavior, so check
  cards, tray, and lightbox still look right.

- [x] **Add link-preview / social metadata.**
  *Done 2026-07-06 (design-D port): meta description, og:title/description/image/url,
  twitter:card, inline-SVG favicon; screenshot.png retaken at 1440px.*
  No meta description, no Open Graph / Twitter card tags, no favicon — links shared
  anywhere will preview blank. Add to the template: `<meta name="description">`,
  `og:title` / `og:description` / `og:image` (use `screenshot.png` — already in the repo
  and served by Pages) / `og:url`, `twitter:card summary_large_image`, and a favicon
  (inline SVG data URI keeps the page dependency-free). Rebuild with `-HtmlOnly`.

- [x] **Sync the README's bundled-image size claim.**
  README says the 512px previews are ~253 MB; on disk `moodboard-images/` is ~297 MB.
  Update the number (and re-check the per-size KB averages if convenient).
  *Done 2026-07-06: both numbers were real (253 MB of bytes, 297 MB allocated on disk —
  cluster overhead across 14K small files); README now states both.*

- [x] **Refine the mood taxonomy: subcategories + a second accuracy pass.**
  *Shipped 2026-07-06: pass-2 records for all 1,539 noir/ethereal boards
  (`krea2-moodboard-mood-registers.json`, 64% consensus, 80 mood corrections; method +
  vocabulary in `taxonomy-mood.md`, script `classify-mood-registers.ps1`), and the
  build-script join + production rail UI landed with the design-D port.*
  - [ ] **Remaining: decide on extending registers to `surreal` (533).** Run the phase-1
    frequency analysis for that bucket first (method in `taxonomy-mood.md`) to pick its
    allowlist, add it to `$ALLOW` in `classify-mood-registers.ps1`, re-run (~11 batches,
    cheap). `medium: film-photography` (1,321, ~37%) is the fattest bucket in any facet
    and arguably the bigger win after that.
  The 10 mood values don't discriminate where it matters: the two fat buckets
  (ethereal-dreamy and noir, ~700-800 boards each) swallow ~40% of the catalog, so
  filtering to them barely narrows. Meanwhile cosmic-mystical (111) and cozy-folk (112)
  are already tight. Subdivide the fat buckets only — don't inflate the whole vocabulary.
  - **Ground the sub-vocabulary in the data**, same as the original pass: frequency
    analysis of titles/keywords *within* each fat bucket (the titles already telegraph
    subfamilies — Liminal Noir, Surveillance Noir, Pictorialist Noir...). Never invent
    values the corpus doesn't support.
  - **Orthogonality check before adopting a sub-value**: drop candidates that merely
    restate another facet (amber-noir ≈ `mood:noir + palette:amber-gold`, already
    expressible by cross-filtering); keep ones that add real signal (liminal,
    surveillance, brutalist, pictorialist, glitch...).
  - **Keep the hierarchy**: `mood` stays as-is for coarse browsing; add a nullable
    `moodDetail`. UI hooks: indented sub-entries under each mood in the index rail
    (design D), and a deeper token grammar (`mood:noir/liminal`) if the prompt-line
    concept (design C) gets adopted into the search box.
  - **Classification = the accuracy pass**: same dual Haiku vote + Sonnet arbiter with
    enum-constrained output, extended provenance (`pass: 2`). Any board whose pass-2
    mood disagrees with pass-1 goes to the arbiter with both labels — mood was one of
    the noisier facets originally (82% single-run agreement pre-tie-break), so this
    doubles as re-validation.
  - **Generalizes next to medium**: film-photography is 1,321 boards (~37%) — the
    fattest bucket in any facet and arguably the bigger win.
  - Cost: comparable to the original full run (~8.4M subagent tokens, a few dollars);
    plus generalizing `classify-new-boards.ps1` to run a scoped re-pass.

- [x] **Remove staff picks entirely — data, UI, and references.**
  *Done 2026-07-06 (design-D port): field dropped from the catalog JSON, no UI traces
  (`grep -ci staffpick` on index.html → 0), README rewritten; the API-field mention in
  the data-source section stays deliberately (it documents Krea's API, not our UI).*
  The "24 staff picks" count in the masthead reads LLM-ish (element-count fixation);
  drop the feature rather than restyle it. Touchpoints, all in
  `build-moodboard-catalog.ps1` unless noted:
  - Catalog: `staffPick = [bool]$_.isStaffPick` (line ~87), the passthrough (~110), and
    the `Select-Object` field list (~116) — drops the field from `krea2-moodboards.json`.
  - Template: `$staffCount` + `__STAFF__` placeholder and its `.Replace()` (~180, ~279,
    ~555), the eyebrow's "· N staff picks" segment, `.staff-toggle` CSS (~220-222 — note
    the favorites checkbox shares this class; keep the styles or rename), the
    "Staff picks" checkbox (~287), the ★ star in card titles (~329).
  - JS: `staffBox` lookup, filter clause in `currentMatches()`, clear-filters reset,
    change listener (~349, ~387, ~395, ~425, ~431).
  - README: "24 staff picks" in Using it (line 21), `isStaffPick` in the API field list
    (43 — arguably keep, it documents the API), `staffPick` in the Files table (74).
  - Rebuild: catalog shape changes, so `-HtmlOnly` isn't enough — run
    `./build-moodboard-catalog.ps1 -SkipImages` (or `-RawJson` if the temp crawl still
    exists) to regenerate JSON + HTML. Retake `screenshot.png` afterward (masthead and
    controls change).
