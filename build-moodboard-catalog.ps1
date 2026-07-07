# build-moodboard-catalog.ps1
# Rebuilds the Krea 2 moodboard reference (docs/moodboards/krea2-moodboards.json + .html + images)
# from Krea's public REST API: GET https://www.krea.ai/api/preset-moodboards?limit&cursor&seed
# (paginated, limit max 96, cursor = offset, no auth required).
#
# Usage:
#   ./build-moodboard-catalog.ps1                 # full run: crawl + json + images + html
#   ./build-moodboard-catalog.ps1 -RawJson x.json # reuse a previous crawl
#   ./build-moodboard-catalog.ps1 -SkipImages     # metadata + html only
#   ./build-moodboard-catalog.ps1 -HtmlOnly       # regenerate html from the existing
#                                                 #   krea2-moodboards.json (no crawl, no images)
#   ./build-moodboard-catalog.ps1 -CleanImages    # wipe image tree first (needed if slug
#                                                 #   assignment changed, e.g. new dupes)
#
# Duplicate board names get -2/-3... suffixes assigned in (createdAt, id) order, so
# suffixes are stable across runs unless Krea inserts an older duplicate.
#
# After a crawl that adds boards, run ./classify-new-boards.ps1 to facet-classify them.

param(
    [string]$RawJson = '',
    [switch]$SkipImages,
    [switch]$HtmlOnly,
    [switch]$CleanImages,
    [int]$Size = 512,
    [int]$Throttle = 12,
    [string]$DocsDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$imgRoot = Join-Path $DocsDir 'moodboard-images'
$jsonOut = Join-Path $DocsDir 'krea2-moodboards.json'
$htmlOut = Join-Path $DocsDir 'index.html'

if ($HtmlOnly) {
    if (-not (Test-Path $jsonOut)) { throw "-HtmlOnly requires an existing $jsonOut" }
    $catalog = Get-Content $jsonOut -Raw | ConvertFrom-Json
    Write-Host "HtmlOnly: loaded $($catalog.Count) boards from $jsonOut"
} else {

# ---- 1. Crawl -------------------------------------------------------------
if ($RawJson -and (Test-Path $RawJson)) {
    Write-Host "Reusing raw crawl: $RawJson"
    $all = Get-Content $RawJson -Raw | ConvertFrom-Json
} else {
    $all = [System.Collections.Generic.List[object]]::new()
    $cursor = 0
    do {
        $u = "https://www.krea.ai/api/preset-moodboards?limit=96&seed=42" + $(if ($cursor) { "&cursor=$cursor" })
        $r = Invoke-RestMethod $u
        $r.items | ForEach-Object { $all.Add($_) }
        Write-Host "  crawled $($all.Count)/$($r.total)"
        $cursor = $r.nextCursor
        Start-Sleep -Milliseconds 200
    } while ($cursor)
    $rawPath = Join-Path $env:TEMP 'krea-moodboards-raw.json'
    $all | ConvertTo-Json -Depth 6 -Compress | Out-File -Encoding utf8 $rawPath
    Write-Host "Raw crawl saved: $rawPath"
}

# ---- 2. Catalog JSON ------------------------------------------------------
function ConvertTo-Slug([string]$name) {
    $d = $name.Normalize([Text.NormalizationForm]::FormD) -creplace '\p{Mn}', ''
    $s = ($d.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $s) { $s = 'moodboard' }
    return $s
}

$seen = @{}
$catalog = $all |
    Sort-Object id -Unique |
    Sort-Object createdAt, id |
    ForEach-Object {
        $base = ConvertTo-Slug $_.name
        if ($seen.ContainsKey($base)) {
            $seen[$base]++
            $slug = "$base-$($seen[$base])"
        } else {
            $seen[$base] = 1
            $slug = $base
        }
        [pscustomobject]@{
            slug      = $slug
            title     = $_.name
            keywords  = ($_.styleKeywords -join ', ')
            profile   = $_.styleDescription
            imageUrls = @($_.previewImages | Select-Object -First 4 | ForEach-Object { $_.url })
            images    = @(1..4 | ForEach-Object { 'moodboard-images/{0}/{1:d2}.webp' -f $slug, $_ })
        }
    }

# Merge facet classifications if present (produced by the dual-vote Haiku sweep;
# boards added by a later crawl simply lack facets until classified)
$facetsFile = Join-Path $DocsDir 'krea2-moodboard-facets.json'
$facetMap = @{}
if (Test-Path $facetsFile) {
    (Get-Content $facetsFile -Raw | ConvertFrom-Json) | ForEach-Object { $facetMap[$_.slug] = $_ }
    Write-Host "Facets: $($facetMap.Count) classifications loaded"
}

# Second left-join: pass-2 mood registers (kept separate from the facets file to preserve
# provenance and the classifier's append/resume model — see taxonomy-mood.md).
# Overrides facets.mood (pass 2 re-validated it) and adds facets.moodDetail (null = plain
# member of the mood; also null for buckets pass 2 hasn't covered).
$registersFile = Join-Path $DocsDir 'krea2-moodboard-mood-registers.json'
$registerMap = @{}
if (Test-Path $registersFile) {
    (Get-Content $registersFile -Raw | ConvertFrom-Json) | ForEach-Object { $registerMap[$_.slug] = $_ }
    Write-Host "Mood registers: $($registerMap.Count) pass-2 records loaded"
}

# imageUrls is a build-time field; strip it from the committed JSON
$catalog = $catalog | ForEach-Object {
    $f = $facetMap[$_.slug]
    $r = $registerMap[$_.slug]
    [pscustomobject]@{
        slug      = $_.slug
        title     = $_.title
        keywords  = $_.keywords
        profile   = $_.profile
        facets    = if ($f) { [pscustomobject]@{
                        medium     = $f.medium
                        mood       = if ($r) { $r.mood } else { $f.mood }
                        moodDetail = if ($r) { $r.moodDetail } else { $null }
                        palette    = $f.palette
                        subject    = $f.subject
                    } } else { $null }
        images    = $_.images
        imageUrls = $_.imageUrls
    }
}
$catalog | Select-Object slug, title, keywords, profile, facets, images |
    ConvertTo-Json -Depth 4 -Compress | Out-File -Encoding utf8 $jsonOut
Write-Host "Catalog: $($catalog.Count) boards -> $jsonOut"
$unclassified = @($catalog | Where-Object { -not $_.facets }).Count
if ($unclassified) { Write-Warning "$unclassified boards have no facets - run ./classify-new-boards.ps1" }

# ---- 3. Images ------------------------------------------------------------
if (-not $SkipImages) {
    if ($CleanImages -and (Test-Path $imgRoot)) { Remove-Item $imgRoot -Recurse -Force }
    New-Item -ItemType Directory -Force $imgRoot | Out-Null

    # prune orphan dirs from earlier runs
    $valid = @{}; $catalog | ForEach-Object { $valid[$_.slug] = $true }
    Get-ChildItem $imgRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $valid.ContainsKey($_.Name) } |
        ForEach-Object { Write-Host "  pruning orphan $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }

    $work = [System.Collections.Generic.List[object]]::new()
    foreach ($mb in $catalog) {
        $dir = Join-Path $imgRoot $mb.slug
        for ($i = 0; $i -lt $mb.imageUrls.Count; $i++) {
            $out = Join-Path $dir ('{0:d2}.webp' -f ($i + 1))
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { continue }
            $cdn = 'https://optim-images.krea.ai/' +
                   ($mb.imageUrls[$i] -replace '://', '---' -replace '[./]', '-') +
                   "-$Size.webp"
            $work.Add([pscustomobject]@{ Url = $cdn; Out = $out; Dir = $dir })
        }
    }
    Write-Host "Images to download: $($work.Count)"

    $failLog = Join-Path $env:TEMP 'moodboard-image-failures.txt'
    if (Test-Path $failLog) { Remove-Item $failLog }
    $done = 0
    foreach ($chunk in ($work | ForEach-Object -Begin { $b = [System.Collections.Generic.List[object]]::new() } -Process { $b.Add($_); if ($b.Count -ge 500) { , $b.ToArray(); $b.Clear() } } -End { if ($b.Count) { , $b.ToArray() } })) {
        $chunk | ForEach-Object -Parallel {
            $item = $_
            New-Item -ItemType Directory -Force $item.Dir | Out-Null
            foreach ($try in 1..2) {
                try {
                    Invoke-WebRequest -Uri $item.Url -OutFile $item.Out -TimeoutSec 30 -ErrorAction Stop
                    return
                } catch {
                    if ($try -eq 2) { Add-Content -Path ($using:failLog) -Value "$($item.Url) -> $($item.Out) : $($_.Exception.Message)" }
                    else { Start-Sleep -Milliseconds 500 }
                }
            }
        } -ThrottleLimit $Throttle
        $done += $chunk.Count
        Write-Host "  downloaded $done/$($work.Count)"
    }
    if (Test-Path $failLog) {
        Write-Warning "Some downloads failed - see $failLog"
    } else {
        Write-Host 'All downloads succeeded.'
    }
}

}  # end -not $HtmlOnly

# ---- 4. HTML --------------------------------------------------------------
$dataJson = Get-Content $jsonOut -Raw
$dataJson = $dataJson.Trim() -replace '</', '<\/'   # keep inline <script> safe
$count = $catalog.Count
$buildDate = Get-Date -Format 'yyyy-MM-dd'

$html = @'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Krea 2 Moodboard Reference</title>
<meta name="description" content="All __COUNT__ Krea preset moodboards in one browsable index: keywords, taste profiles, and preview images, faceted by medium, mood, palette, and subject. A prompting reference for Krea 2.">
<meta property="og:title" content="Krea 2 Moodboard Reference">
<meta property="og:description" content="All __COUNT__ Krea preset moodboards in one browsable index: keywords, taste profiles, and preview images, faceted by medium, mood, palette, and subject.">
<meta property="og:image" content="https://altinfire.github.io/krea2-moodboard/screenshot.png">
<meta property="og:url" content="https://altinfire.github.io/krea2-moodboard/">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect width='16' height='16' rx='3' fill='%23131316'/><rect x='2.5' y='2.5' width='5' height='5' rx='1' fill='%23e3a857'/><rect x='8.5' y='2.5' width='5' height='5' rx='1' fill='%2336363e'/><rect x='2.5' y='8.5' width='5' height='5' rx='1' fill='%2336363e'/><rect x='8.5' y='8.5' width='5' height='5' rx='1' fill='%23524a3a'/></svg>">
<style>
  :root {
    --bg: #0a0a0c; --surface: #131316; --surface-2: #1a1a1f; --surface-3: #24242b;
    --border: #222228; --border-bright: #36363e;
    --text: #e8e8ea; --dim: #9a9aa2; --faint: #686871;
    --accent: #e3a857; --accent-soft: rgba(227,168,87,0.55); --accent-ink: #171207;
    --heart: #e0605f;
    --serif: 'Palatino Linotype', Palatino, Georgia, serif;
    --sans: system-ui, -apple-system, 'Segoe UI', sans-serif;
    --mono: ui-monospace, 'Cascadia Mono', Consolas, monospace;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html { color-scheme: dark; }
  body { background: var(--bg); color: var(--text); font-family: var(--sans); display: flex; max-width: 1640px; margin: 0 auto; }
  body.tray-open #plates { padding-bottom: 110px; }
  ::selection { background: rgba(227,168,87,0.3); }
  :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

  /* ---- the index rail ---- */
  #rail { width: 264px; flex-shrink: 0; position: sticky; top: 0; height: 100vh; overflow-y: auto; padding: 30px 22px 20px 24px; border-right: 1px solid var(--border); scrollbar-width: thin; scrollbar-color: var(--border-bright) transparent; }
  .eyebrow { font-family: var(--mono); font-size: 0.66rem; letter-spacing: 0.06em; color: var(--faint); margin-bottom: 10px; }
  h1 { font-family: var(--serif); font-size: 1.45rem; font-weight: 400; letter-spacing: 0.01em; line-height: 1.25; margin-bottom: 8px; }
  .subtitle { color: var(--dim); font-size: 0.78rem; line-height: 1.55; margin-bottom: 16px; }
  .search-bar { width: 100%; padding: 9px 12px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; color: var(--text); font-size: 0.85rem; font-family: var(--sans); margin-bottom: 20px; }
  .search-bar::placeholder { color: var(--faint); }
  .search-bar:focus { outline: none; border-color: var(--accent-soft); }

  .ix-group { margin-bottom: 18px; }
  .ix-group h2 { font-family: var(--mono); font-size: 0.64rem; font-weight: 400; letter-spacing: 0.14em; text-transform: uppercase; color: var(--faint); margin-bottom: 7px; }
  .ix-row { display: flex; align-items: flex-end; width: 100%; background: none; border: none; cursor: pointer; padding: 2.5px 0; font-family: var(--sans); text-align: left; }
  .ix-label { color: var(--dim); font-size: 0.8rem; white-space: nowrap; transition: color 0.15s; }
  .ix-leader { flex: 1; border-bottom: 1px dotted #35353d; margin: 0 7px; transform: translateY(-4px); min-width: 12px; }
  .ix-count { font-family: var(--mono); font-size: 0.68rem; color: var(--faint); transition: color 0.15s; }
  .ix-row:hover .ix-label { color: var(--text); }
  .ix-row.active .ix-label { color: var(--accent); }
  .ix-row.active .ix-count { color: var(--accent); }
  .ix-row.active .ix-leader { border-bottom-color: var(--accent-soft); }
  .ix-row .ix-heart { color: var(--heart); font-size: 0.75rem; margin-right: 6px; }
  .ix-row.sub { padding-left: 16px; }
  .ix-row.sub .ix-label { font-size: 0.74rem; }
  #rail footer { font-family: var(--mono); color: var(--faint); font-size: 0.62rem; line-height: 1.7; letter-spacing: 0.02em; margin-top: 26px; padding-top: 14px; border-top: 1px solid var(--border); }
  #rail footer a { color: var(--dim); }
  #rail footer a:hover { color: var(--accent); }

  /* ---- plates ---- */
  main { flex: 1; min-width: 0; padding: 0 24px 24px; }
  .statusbar { position: sticky; top: 0; z-index: 50; display: flex; align-items: center; gap: 14px; padding: 16px 2px 12px; background: rgba(10,10,12,0.86); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); margin-bottom: 18px; }
  #count { font-family: var(--mono); color: var(--faint); font-size: 0.72rem; letter-spacing: 0.03em; flex: 1; min-width: 0; }
  .btn-primary { background: var(--accent); border: 1px solid var(--accent); color: var(--accent-ink); font-weight: 600; padding: 8px 18px; border-radius: 8px; font-size: 0.83rem; font-family: var(--sans); cursor: pointer; white-space: nowrap; transition: background-color 0.15s; }
  .btn-primary:hover { background: #ecb96e; border-color: #ecb96e; }
  .verb { background: none; border: none; color: var(--dim); font-size: 0.8rem; font-family: var(--sans); cursor: pointer; padding: 4px 2px; white-space: nowrap; }
  .verb:hover { color: var(--text); text-decoration: underline; text-underline-offset: 3px; text-decoration-color: var(--accent-soft); }

  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 20px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; overflow: hidden; transition: border-color 0.15s; }
  .card:hover { border-color: var(--border-bright); }
  .card-images { display: grid; grid-template-columns: repeat(4, 1fr); gap: 2px; background: var(--surface); }
  .card-images img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; background: var(--surface-2); cursor: zoom-in; }
  .card-body { padding: 14px 16px 16px; }
  .card-title { font-family: var(--serif); font-size: 1.05rem; font-weight: 400; margin-bottom: 7px; display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .title-btns { display: flex; align-items: center; gap: 4px; flex-shrink: 0; }
  .copy-btn { background: none; border: none; color: var(--faint); padding: 3px 6px; cursor: pointer; font-size: 0.68rem; font-family: var(--mono); white-space: nowrap; transition: color 0.15s; }
  .copy-btn:hover { color: var(--text); }
  .copy-btn.copied { color: var(--accent); }
  .fav-btn { background: none; border: none; color: var(--faint); cursor: pointer; font-size: 1.05rem; padding: 0 3px; line-height: 1; transition: color 0.15s; }
  .fav-btn:hover, .fav-btn.faved { color: var(--heart); }
  .facet-line { font-family: var(--mono); color: var(--faint); font-size: 0.68rem; letter-spacing: 0.02em; margin-bottom: 9px; }
  .facet-chip { cursor: pointer; }
  .facet-chip:hover { color: var(--accent); }
  .profile { color: var(--dim); font-size: 0.8rem; line-height: 1.55; margin-bottom: 11px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; cursor: pointer; }
  .profile.open { -webkit-line-clamp: unset; }
  .pills { display: flex; flex-wrap: wrap; gap: 5px; }
  .pill { background: var(--surface-2); color: #b8b8c0; padding: 3px 9px; border-radius: 6px; font-size: 0.73rem; white-space: nowrap; cursor: pointer; user-select: none; transition: background-color 0.15s, color 0.15s; }
  .pill:hover { background: var(--surface-3); color: var(--text); }
  .pill.sel { background: var(--accent); color: var(--accent-ink); }
  .empty { color: var(--dim); font-size: 0.9rem; padding: 56px 0; text-align: center; }
  .empty .verb { font-size: 0.9rem; color: var(--accent); }

  /* ---- tray ---- */
  #tray { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); width: max-content; max-width: min(920px, 94vw); background: rgba(19,19,22,0.88); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); border: 1px solid var(--border-bright); border-radius: 14px; padding: 10px 12px 10px 16px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; z-index: 90; box-shadow: 0 12px 40px rgba(0,0,0,0.55); }
  .tray-label { font-family: var(--mono); color: var(--faint); font-size: 0.7rem; letter-spacing: 0.04em; white-space: nowrap; }
  #trayChips { display: flex; flex-wrap: wrap; gap: 5px; flex: 1; min-width: 200px; }
  .tray-chip { background: rgba(227,168,87,0.13); color: #e6c48f; padding: 3px 6px 3px 9px; border-radius: 6px; font-size: 0.73rem; display: inline-flex; align-items: center; gap: 4px; white-space: nowrap; }
  .chip-x { background: none; border: none; color: inherit; opacity: 0.7; cursor: pointer; font-size: 0.95rem; padding: 0 2px; line-height: 1; }
  .chip-x:hover { opacity: 1; color: var(--heart); }
  #trayCopy { background: var(--accent); border: 1px solid var(--accent); color: var(--accent-ink); font-weight: 600; padding: 7px 14px; border-radius: 8px; font-size: 0.8rem; font-family: var(--sans); cursor: pointer; }
  #trayCopy:hover { background: #ecb96e; border-color: #ecb96e; }

  /* ---- lightbox ---- */
  #lightbox { position: fixed; inset: 0; background: rgba(8,8,10,0.93); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); z-index: 100; display: none; align-items: center; justify-content: center; flex-direction: column; gap: 14px; }
  #lb-img { max-width: min(90vw, 768px); max-height: 80vh; border-radius: 6px; box-shadow: 0 24px 80px rgba(0,0,0,0.7); }
  #lb-caption { display: flex; align-items: baseline; gap: 12px; }
  #lb-title { font-family: var(--serif); font-size: 1rem; color: var(--text); }
  #lb-counter { font-family: var(--mono); font-size: 0.7rem; color: var(--faint); letter-spacing: 0.04em; }
  .lb-nav { position: fixed; top: 50%; transform: translateY(-50%); background: rgba(19,19,22,0.7); border: 1px solid var(--border-bright); color: var(--dim); font-size: 1.5rem; width: 44px; height: 44px; border-radius: 50%; cursor: pointer; line-height: 1; transition: color 0.15s, border-color 0.15s; }
  .lb-nav:hover { color: var(--text); border-color: var(--accent-soft); }
  #lb-prev { left: 16px; }
  #lb-next { right: 16px; }

  @media (max-width: 980px) {
    body { flex-direction: column; }
    #rail { position: static; width: auto; height: auto; border-right: none; border-bottom: 1px solid var(--border); padding: 22px 16px 14px; }
    .ix-group h2 { margin-bottom: 8px; }
    .ix-row { display: inline-flex; width: auto; border: 1px solid var(--border); border-radius: 6px; padding: 3px 9px; margin: 0 4px 5px 0; align-items: center; gap: 6px; }
    .ix-leader { display: none; }
    .ix-row.active { border-color: var(--accent-soft); }
    main { padding: 0 14px 14px; }
    .grid { grid-template-columns: 1fr; gap: 14px; }
  }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
</style>

<aside id="rail">
  <p class="eyebrow">__COUNT__ preset moodboards<br>data &amp; images from krea.ai</p>
  <h1>Krea 2 Moodboard Reference</h1>
  <p class="subtitle">Keywords and taste profiles for Krea 2 prompting. Click keywords to collect them into a combined prompt.</p>
  <input class="search-bar" type="text" placeholder="Search &mdash; press /" id="search">
  <nav id="ixNav"></nav>
  <footer>unofficial community reference &middot; data &amp; images from <a href="https://www.krea.ai">krea.ai</a><br>built __BUILDDATE__</footer>
</aside>

<main>
  <div class="statusbar">
    <p id="count"></p>
    <button class="verb" id="clearBtn" style="display:none">Clear filters</button>
    <button class="verb" id="showAllBtn" style="display:none">Show all</button>
    <button class="btn-primary" id="shuffleBtn" title="Deal a fresh random selection">Shuffle</button>
  </div>
  <div class="grid" id="grid"></div>
  <div class="empty" id="empty" style="display:none">No boards match. Loosen a filter, or <button class="verb" id="clearBtn2">clear everything</button>.</div>
</main>

<div id="tray" style="display:none">
  <span class="tray-label">Prompt keywords:</span>
  <div id="trayChips"></div>
  <button id="trayCopy">Copy</button>
  <button class="verb" id="trayClear">Clear</button>
</div>

<div id="lightbox">
  <button class="lb-nav" id="lb-prev" title="Previous (&larr;)">&#8249;</button>
  <img id="lb-img" src="" alt="">
  <div id="lb-caption"><span id="lb-title"></span><span id="lb-counter"></span></div>
  <button class="lb-nav" id="lb-next" title="Next (&rarr;)">&#8250;</button>
</div>

<script>
const DATA_RAW = __DATA__;
const DATA = DATA_RAW.sort((a, b) => a.title.localeCompare(b.title));
const SAMPLE_N = 60;
const FACET_KEYS = ['medium','mood','palette','subject'];
const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmt = n => n.toLocaleString('en-US');
const facetLabel = (k, v) => (k === 'subject' && v === 'none') ? 'style-only (any subject)' : v;

const grid = document.getElementById('grid');
grid.innerHTML = DATA.map((m, i) => `<div class="card" data-i="${i}">
  <div class="card-images">${m.images.map(src =>
    `<img src="${src}" alt="" loading="lazy" decoding="async">`
  ).join('')}</div>
  <div class="card-body">
    <div class="card-title">
      <span>${esc(m.title)}</span>
      <span class="title-btns">
        <button class="fav-btn" title="Add to favorites">&#9825;</button>
        <button class="copy-btn">copy keywords</button>
      </span>
    </div>
    ${m.facets ? `<p class="facet-line">${FACET_KEYS.filter(k => m.facets[k] && m.facets[k] !== 'none').map(k => {
      const d = (k === 'mood' && m.facets.moodDetail) ? m.facets.moodDetail : null;
      const label = d ? `${m.facets[k]} / ${d}` : m.facets[k];
      return `<span class="facet-chip" data-k="${k}" data-v="${m.facets[k]}"${d ? ` data-d="${d}"` : ''} title="Filter by ${label}">${label}</span>`;
    }).join(' &middot; ')}</p>` : ''}
    <p class="profile" title="Click to expand">${esc(m.profile || '')}</p>
    <div class="pills">${m.keywords.split(',').map(k =>
      `<span class="pill" data-kw="${esc(k.trim())}" title="Click to add to prompt keywords">${esc(k.trim())}</span>`
    ).join('')}</div>
  </div>
</div>`).join('');

const cards = [...grid.children];
const hay = DATA.map(m => (m.title + ' ' + m.keywords + ' ' + (m.profile || '')).toLowerCase());
const countEl = document.getElementById('count');
const emptyEl = document.getElementById('empty');
const searchEl = document.getElementById('search');
const shuffleBtn = document.getElementById('shuffleBtn');
const showAllBtn = document.getElementById('showAllBtn');
const clearBtn = document.getElementById('clearBtn');

// ---- the index ----
const sel = { medium: null, mood: null, palette: null, subject: null };
let selDetail = null;
let favOnly = false;
const counts = {};
FACET_KEYS.forEach(k => {
  counts[k] = {};
  DATA.forEach(m => { const v = m.facets && m.facets[k]; if (v) counts[k][v] = (counts[k][v] || 0) + 1; });
});
const detailCounts = {};
DATA.forEach(m => {
  const f = m.facets;
  if (f && f.moodDetail) {
    detailCounts[f.mood] = detailCounts[f.mood] || {};
    detailCounts[f.mood][f.moodDetail] = (detailCounts[f.mood][f.moodDetail] || 0) + 1;
  }
});
const ixNav = document.getElementById('ixNav');
ixNav.innerHTML = FACET_KEYS.map(k => `<section class="ix-group">
  <h2>${k}</h2>
  ${Object.keys(counts[k]).sort((a, b) => (a === 'none') - (b === 'none') || a.localeCompare(b)).map(v =>
    `<button class="ix-row" data-k="${k}" data-v="${v}"><span class="ix-label">${facetLabel(k, v)}</span><span class="ix-leader"></span><span class="ix-count">${fmt(counts[k][v])}</span></button>` +
    ((k === 'mood' && detailCounts[v]) ? Object.keys(detailCounts[v]).sort().map(d =>
      `<button class="ix-row sub" data-k="mood" data-v="${v}" data-d="${d}"><span class="ix-label">${d}</span><span class="ix-leader"></span><span class="ix-count">${fmt(detailCounts[v][d])}</span></button>`
    ).join('') : '')
  ).join('')}
</section>`).join('') + `<section class="ix-group">
  <h2>collection</h2>
  <button class="ix-row" id="favRow"><span class="ix-heart">&#9829;</span><span class="ix-label">favorites</span><span class="ix-leader"></span><span class="ix-count" id="favCount">0</span></button>
</section>`;

function syncIndex() {
  ixNav.querySelectorAll('.ix-row[data-k]').forEach(r => {
    if (r.dataset.d) r.classList.toggle('active', sel.mood === r.dataset.v && selDetail === r.dataset.d);
    else r.classList.toggle('active', sel[r.dataset.k] === r.dataset.v);
  });
  document.getElementById('favRow').classList.toggle('active', favOnly);
  const active = FACET_KEYS.some(k => sel[k]) || selDetail || favOnly || searchEl.value.trim();
  clearBtn.style.display = active ? '' : 'none';
}
function applyFacet(k, v) {
  sel[k] = (sel[k] === v) ? null : v;
  sampleSet = null; syncIndex(); render();
}
ixNav.addEventListener('click', e => {
  const row = e.target.closest('.ix-row');
  if (!row) return;
  if (row.id === 'favRow') { favOnly = !favOnly; sampleSet = null; syncIndex(); render(); return; }
  if (row.dataset.d) {
    if (sel.mood === row.dataset.v && selDetail === row.dataset.d) { sel.mood = null; selDetail = null; }
    else { sel.mood = row.dataset.v; selDetail = row.dataset.d; }
    sampleSet = null; syncIndex(); render(); return;
  }
  if (row.dataset.k === 'mood') {
    if (selDetail && sel.mood === row.dataset.v) { selDetail = null; sampleSet = null; syncIndex(); render(); return; }
    selDetail = null;
  }
  applyFacet(row.dataset.k, row.dataset.v);
});

// ---- persistent state ----
const store = (key, val) => { try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) {} };
const load = (key, fallback) => { try { return JSON.parse(localStorage.getItem(key)) || fallback; } catch (e) { return fallback; } };
const favs = new Set(load('krea-mb-favs', []));
let tray = load('krea-mb-tray', []);
const favCountEl = document.getElementById('favCount');
const syncFavCount = () => { favCountEl.textContent = fmt(favs.size); };
syncFavCount();

const pillIndex = {};
grid.querySelectorAll('.pill').forEach(p => {
  (pillIndex[p.dataset.kw] = pillIndex[p.dataset.kw] || []).push(p);
});

// ---- filtering ----
let sampleSet = null;

function currentMatches() {
  const q = searchEl.value.toLowerCase().trim();
  const wantKeys = FACET_KEYS.filter(k => sel[k]);
  const out = [];
  for (let i = 0; i < DATA.length; i++) {
    const m = DATA[i];
    if ((!q || hay[i].includes(q)) && (!favOnly || favs.has(m.slug)) &&
        wantKeys.every(k => m.facets && m.facets[k] === sel[k]) &&
        (!selDetail || (m.facets && m.facets.moodDetail === selDetail))) out.push(i);
  }
  return out;
}

function resample() {
  const matches = currentMatches();
  for (let i = matches.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    const t = matches[i]; matches[i] = matches[j]; matches[j] = t;
  }
  sampleSet = new Set(matches.slice(0, SAMPLE_N));
}

function render() {
  const matches = currentMatches();
  const visible = sampleSet ? matches.filter(i => sampleSet.has(i)) : matches;
  const vis = new Set(visible);
  cards.forEach((c, i) => { c.style.display = vis.has(i) ? '' : 'none'; });
  emptyEl.style.display = visible.length ? 'none' : '';
  showAllBtn.style.display = sampleSet ? '' : 'none';
  countEl.textContent = sampleSet
    ? `showing ${fmt(visible.length)} random of ${fmt(matches.length)} boards · Shuffle deals another hand`
    : `showing ${fmt(visible.length)} of ${fmt(DATA.length)} boards`;
}

function clearAll() {
  searchEl.value = '';
  FACET_KEYS.forEach(k => { sel[k] = null; });
  selDetail = null;
  favOnly = false;
  sampleSet = null; syncIndex(); render();
}
shuffleBtn.addEventListener('click', () => { resample(); render(); window.scrollTo({top: 0}); });
showAllBtn.addEventListener('click', () => { sampleSet = null; render(); });
clearBtn.addEventListener('click', clearAll);
document.getElementById('clearBtn2').addEventListener('click', clearAll);
let deb;
searchEl.addEventListener('input', () => { clearTimeout(deb); deb = setTimeout(() => { sampleSet = null; syncIndex(); render(); }, 120); });

// ---- favorites ----
function syncFav(card, faved) {
  const btn = card.querySelector('.fav-btn');
  btn.innerHTML = faved ? '&#9829;' : '&#9825;';
  btn.classList.toggle('faved', faved);
  btn.title = faved ? 'Remove from favorites' : 'Add to favorites';
}
cards.forEach((c, i) => { if (favs.has(DATA[i].slug)) syncFav(c, true); });

// ---- prompt tray ----
const trayEl = document.getElementById('tray');
const trayChips = document.getElementById('trayChips');
const trayCopy = document.getElementById('trayCopy');

function renderTray() {
  trayEl.style.display = tray.length ? '' : 'none';
  document.body.classList.toggle('tray-open', tray.length > 0);
  trayChips.innerHTML = tray.map(k =>
    `<span class="tray-chip">${esc(k)}<button class="chip-x" data-kw="${esc(k)}" title="Remove">&times;</button></span>`
  ).join('');
}
function toggleKw(kw) {
  const i = tray.indexOf(kw);
  if (i >= 0) tray.splice(i, 1); else tray.push(kw);
  store('krea-mb-tray', tray);
  renderTray();
  (pillIndex[kw] || []).forEach(p => p.classList.toggle('sel', tray.includes(kw)));
}
trayEl.addEventListener('click', e => {
  if (e.target.classList.contains('chip-x')) toggleKw(e.target.dataset.kw);
});
trayCopy.addEventListener('click', () => {
  navigator.clipboard.writeText(tray.join(', ')).then(() => {
    trayCopy.textContent = 'Copied';
    setTimeout(() => { trayCopy.textContent = 'Copy'; }, 1500);
  });
});
document.getElementById('trayClear').addEventListener('click', () => {
  tray.slice().forEach(kw => (pillIndex[kw] || []).forEach(p => p.classList.remove('sel')));
  tray = [];
  store('krea-mb-tray', tray);
  renderTray();
});
tray.forEach(kw => (pillIndex[kw] || []).forEach(p => p.classList.add('sel')));
renderTray();

// ---- lightbox ----
const lb = document.getElementById('lightbox');
const lbImg = document.getElementById('lb-img');
const lbTitle = document.getElementById('lb-title');
const lbCounter = document.getElementById('lb-counter');
let lbBoard = 0, lbIdx = 0;
function lbShow() {
  const m = DATA[lbBoard];
  lbImg.src = m.images[lbIdx];
  lbTitle.textContent = m.title;
  lbCounter.textContent = `${lbIdx + 1} / ${m.images.length}`;
}
function lbOpen(bi, ii) { lbBoard = bi; lbIdx = ii; lbShow(); lb.style.display = 'flex'; }
function lbClose() { lb.style.display = 'none'; lbImg.src = ''; }
function lbStep(d) {
  const n = DATA[lbBoard].images.length;
  lbIdx = (lbIdx + d + n) % n;
  lbShow();
}
document.getElementById('lb-prev').addEventListener('click', () => lbStep(-1));
document.getElementById('lb-next').addEventListener('click', () => lbStep(1));
lb.addEventListener('click', e => { if (e.target === lb) lbClose(); });

// ---- keyboard ----
document.addEventListener('keydown', e => {
  if (lb.style.display !== 'none' && lb.style.display !== '') {
    if (e.key === 'Escape') lbClose();
    else if (e.key === 'ArrowLeft') lbStep(-1);
    else if (e.key === 'ArrowRight') lbStep(1);
    return;
  }
  if (e.key === '/' && document.activeElement !== searchEl && !/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName)) {
    e.preventDefault(); searchEl.focus();
  }
});

// ---- card interactions (delegated) ----
grid.addEventListener('click', e => {
  const t = e.target;
  if (t.classList.contains('profile')) { t.classList.toggle('open'); return; }
  if (t.classList.contains('pill')) { toggleKw(t.dataset.kw); return; }
  if (t.classList.contains('facet-chip')) {
    sel[t.dataset.k] = t.dataset.v;
    if (t.dataset.k === 'mood') selDetail = t.dataset.d || null;
    sampleSet = null; syncIndex(); render(); window.scrollTo({top: 0});
    return;
  }
  const card = t.closest('.card');
  if (!card) return;
  const i = +card.dataset.i;
  if (t.classList.contains('fav-btn')) {
    const slug = DATA[i].slug;
    if (favs.has(slug)) favs.delete(slug); else favs.add(slug);
    store('krea-mb-favs', [...favs]);
    syncFav(card, favs.has(slug));
    syncFavCount();
    if (favOnly) render();
    return;
  }
  if (t.classList.contains('copy-btn')) {
    navigator.clipboard.writeText(DATA[i].keywords).then(() => {
      t.textContent = 'copied';
      t.classList.add('copied');
      setTimeout(() => { t.textContent = 'copy keywords'; t.classList.remove('copied'); }, 1500);
    });
    return;
  }
  if (t.tagName === 'IMG' && t.closest('.card-images')) {
    lbOpen(i, [...t.parentElement.children].indexOf(t));
  }
});

resample();
syncIndex();
render();
</script>
'@

$html = $html.Replace('__COUNT__', $count.ToString('N0')).Replace('__DATA__', $dataJson).Replace('__BUILDDATE__', $buildDate)
$html | Out-File -Encoding utf8 $htmlOut
Write-Host "HTML: $htmlOut ($([math]::Round((Get-Item $htmlOut).Length/1MB,1)) MB)"

