# Backlog

Pre-announce polish. `index.html` and `krea2-moodboards.json` are generated — every fix
lands in `build-moodboard-catalog.ps1` (or README) and gets rebuilt, never hand-edited.

- [ ] **HIGH: fix renderer hard-freeze — remove `content-visibility: auto` from `.card`.**
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

- [ ] **Fix quirks mode: add a proper document skeleton to the HTML template.**
  The template in `build-moodboard-catalog.ps1` starts at `<meta charset>` with no
  `<!doctype html>`, so browsers render the page in quirks mode and the layout works by
  accident. Add `<!doctype html>` + `<html lang="en">`, then rebuild with `-HtmlOnly` and
  eyeball the layout — quirks mode changes box-model/line-height behavior, so check
  cards, tray, and lightbox still look right.

- [ ] **Add link-preview / social metadata.**
  No meta description, no Open Graph / Twitter card tags, no favicon — links shared
  anywhere will preview blank. Add to the template: `<meta name="description">`,
  `og:title` / `og:description` / `og:image` (use `screenshot.png` — already in the repo
  and served by Pages) / `og:url`, `twitter:card summary_large_image`, and a favicon
  (inline SVG data URI keeps the page dependency-free). Rebuild with `-HtmlOnly`.

- [ ] **Sync the README's bundled-image size claim.**
  README says the 512px previews are ~253 MB; on disk `moodboard-images/` is ~297 MB.
  Update the number (and re-check the per-size KB averages if convenient).

- [ ] **Refine the mood taxonomy: subcategories + a second accuracy pass.**
  *Status 2026-07-06: classification DONE — all 1,539 noir/ethereal boards have pass-2
  records in `krea2-moodboard-mood-registers.json` (64% consensus, 80 mood corrections;
  method + vocabulary in `taxonomy-mood.md`, script `classify-mood-registers.ps1`).
  Registers are browsable in the design-d prototype rail. Remaining: fold `moodDetail`
  into the build-script join + production UI once a design wins, and decide on extending
  to `surreal` (533).*
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

- [ ] **Remove staff picks entirely — data, UI, and references.**
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
