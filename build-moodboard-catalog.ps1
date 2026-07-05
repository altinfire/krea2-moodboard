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
            staffPick = [bool]$_.isStaffPick
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

# imageUrls is a build-time field; strip it from the committed JSON
$catalog = $catalog | ForEach-Object {
    $f = $facetMap[$_.slug]
    [pscustomobject]@{
        slug      = $_.slug
        title     = $_.title
        keywords  = $_.keywords
        profile   = $_.profile
        staffPick = $_.staffPick
        facets    = if ($f) { [pscustomobject]@{ medium = $f.medium; mood = $f.mood; palette = $f.palette; subject = $f.subject } } else { $null }
        images    = $_.images
        imageUrls = $_.imageUrls
    }
}
$catalog | Select-Object slug, title, keywords, profile, staffPick, facets, images |
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
$staffCount = @($catalog | Where-Object staffPick).Count
$buildDate = Get-Date -Format 'yyyy-MM-dd'

$html = @'
<meta charset="utf-8">
<title>Krea 2 Moodboard Reference</title>
<style>
  :root { --bg: #0a0a0a; --card: #151515; --border: #252525; --text: #e0e0e0; --dim: #888; --accent: #6366f1; --pill-bg: #1e1e2e; --pill-text: #a5b4fc; --heart: #f87171; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 24px; max-width: 1400px; margin: 0 auto; }
  body.tray-open { padding-bottom: 96px; }
  h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 4px; }
  .subtitle { color: var(--dim); font-size: 0.85rem; margin-bottom: 20px; }
  .controls { display: flex; gap: 12px; align-items: center; margin-bottom: 12px; flex-wrap: wrap; }
  .search-bar { flex: 1; min-width: 240px; padding: 10px 16px; background: var(--card); border: 1px solid var(--border); border-radius: 8px; color: var(--text); font-size: 0.95rem; outline: none; }
  .search-bar:focus { border-color: var(--accent); }
  .btn { padding: 9px 14px; background: var(--card); border: 1px solid var(--border); border-radius: 8px; color: var(--text); font-size: 0.85rem; cursor: pointer; white-space: nowrap; }
  .btn:hover { border-color: var(--accent); color: var(--accent); }
  .facet-select { padding: 8px 10px; background: var(--card); border: 1px solid var(--border); border-radius: 8px; color: var(--text); font-size: 0.85rem; outline: none; cursor: pointer; }
  .facet-select:focus { border-color: var(--accent); }
  .facet-line { color: var(--dim); font-size: 0.72rem; letter-spacing: 0.02em; margin-bottom: 8px; }
  .facet-chip { cursor: pointer; }
  .facet-chip:hover { color: var(--pill-text); text-decoration: underline; }
  .staff-toggle { color: var(--dim); font-size: 0.85rem; display: flex; gap: 6px; align-items: center; cursor: pointer; white-space: nowrap; user-select: none; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); gap: 20px; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; transition: border-color 0.2s; content-visibility: auto; contain-intrinsic-size: auto 340px; }
  .card:hover { border-color: #444; }
  .card-images { display: grid; grid-template-columns: repeat(4, 1fr); gap: 2px; }
  .card-images img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; background: #222; cursor: zoom-in; }
  .card-body { padding: 14px 16px; }
  .card-title { font-size: 1rem; font-weight: 600; margin-bottom: 8px; display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .title-btns { display: flex; align-items: center; gap: 4px; flex-shrink: 0; }
  .star { color: #fbbf24; font-size: 0.85rem; }
  .copy-btn { background: none; border: 1px solid var(--border); color: var(--dim); padding: 3px 10px; border-radius: 4px; cursor: pointer; font-size: 0.75rem; white-space: nowrap; }
  .copy-btn:hover { border-color: var(--accent); color: var(--accent); }
  .copy-btn.copied { color: #4ade80; border-color: #4ade80; }
  .fav-btn { background: none; border: none; color: var(--dim); cursor: pointer; font-size: 1.05rem; padding: 0 4px; line-height: 1; }
  .fav-btn:hover, .fav-btn.faved { color: var(--heart); }
  .profile { color: var(--dim); font-size: 0.8rem; line-height: 1.45; margin-bottom: 10px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; cursor: pointer; }
  .profile.open { -webkit-line-clamp: unset; }
  .pills { display: flex; flex-wrap: wrap; gap: 6px; }
  .pill { background: var(--pill-bg); color: var(--pill-text); padding: 3px 10px; border-radius: 20px; font-size: 0.75rem; white-space: nowrap; cursor: pointer; user-select: none; }
  .pill:hover { outline: 1px solid var(--accent); }
  .pill.sel { background: var(--accent); color: #fff; }
  .count { color: var(--dim); font-size: 0.85rem; margin-bottom: 16px; }
  .empty { color: var(--dim); font-size: 0.95rem; padding: 48px 0; text-align: center; }
  footer { color: var(--dim); font-size: 0.78rem; margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--border); text-align: center; }
  footer a { color: var(--pill-text); }
  #tray { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); max-width: min(920px, 94vw); background: #151515f2; border: 1px solid #333; border-radius: 12px; padding: 10px 14px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap; z-index: 90; box-shadow: 0 8px 32px rgba(0,0,0,0.6); }
  .tray-label { color: var(--dim); font-size: 0.8rem; white-space: nowrap; }
  #trayChips { display: flex; flex-wrap: wrap; gap: 6px; flex: 1; min-width: 200px; }
  .tray-chip { background: var(--pill-bg); color: var(--pill-text); padding: 3px 6px 3px 10px; border-radius: 20px; font-size: 0.75rem; display: inline-flex; align-items: center; gap: 4px; white-space: nowrap; }
  .chip-x { background: none; border: none; color: var(--pill-text); cursor: pointer; font-size: 0.95rem; padding: 0 2px; line-height: 1; }
  .chip-x:hover { color: var(--heart); }
  #lightbox { position: fixed; inset: 0; background: rgba(0,0,0,0.9); z-index: 100; display: none; align-items: center; justify-content: center; flex-direction: column; gap: 12px; }
  #lb-img { max-width: min(90vw, 768px); max-height: 80vh; border-radius: 8px; }
  #lb-caption { color: var(--dim); font-size: 0.85rem; }
  .lb-nav { position: fixed; top: 50%; transform: translateY(-50%); background: #151515cc; border: 1px solid #333; color: var(--text); font-size: 1.6rem; width: 44px; height: 44px; border-radius: 50%; cursor: pointer; line-height: 1; }
  .lb-nav:hover { border-color: var(--accent); color: var(--accent); }
  #lb-prev { left: 16px; }
  #lb-next { right: 16px; }
  @media (max-width: 600px) { .grid { grid-template-columns: 1fr; } body { padding: 12px; } }
</style>

<h1>Krea 2 Moodboard Reference</h1>
<p class="subtitle">__COUNT__ preset moodboards from krea.ai (__STAFF__ staff picks) - keywords and taste profiles for Krea 2 prompting. Click keyword pills to build a combined prompt, click images to zoom, &hearts; to save favorites.</p>
<div class="controls">
  <input class="search-bar" type="text" placeholder="Filter by title, keyword, or profile...  (press / to focus)" id="search">
  <button class="btn" id="shuffleBtn" title="Show a fresh random selection">&#127922; Shuffle</button>
  <button class="btn" id="showAllBtn">Show all</button>
  <label class="staff-toggle"><input type="checkbox" id="staffOnly"> Staff picks</label>
  <label class="staff-toggle"><input type="checkbox" id="favOnly"> &hearts; Favorites</label>
</div>
<div class="controls" id="facetControls">
  <select class="facet-select" id="f-medium"><option value="">All media</option></select>
  <select class="facet-select" id="f-mood"><option value="">All moods</option></select>
  <select class="facet-select" id="f-palette"><option value="">All palettes</option></select>
  <select class="facet-select" id="f-subject"><option value="">All subjects</option></select>
</div>
<p class="count" id="count"></p>
<div class="grid" id="grid"></div>
<div class="empty" id="empty" style="display:none">No moodboards match. <button class="btn" id="clearBtn">Clear filters</button></div>
<footer>Unofficial community reference &middot; moodboard data &amp; images from <a href="https://www.krea.ai">krea.ai</a> preset moodboards &middot; built __BUILDDATE__</footer>

<div id="tray" style="display:none">
  <span class="tray-label">Prompt keywords:</span>
  <div id="trayChips"></div>
  <button class="btn" id="trayCopy">Copy</button>
  <button class="btn" id="trayClear">Clear</button>
</div>

<div id="lightbox">
  <button class="lb-nav" id="lb-prev" title="Previous (&larr;)">&#8249;</button>
  <img id="lb-img" src="" alt="">
  <div id="lb-caption"></div>
  <button class="lb-nav" id="lb-next" title="Next (&rarr;)">&#8250;</button>
</div>

<script>
const DATA_RAW = __DATA__;
const DATA = DATA_RAW.sort((a, b) => a.title.localeCompare(b.title));
const SAMPLE_N = 60;
const FACET_KEYS = ['medium','mood','palette','subject'];
const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const grid = document.getElementById('grid');
grid.innerHTML = DATA.map((m, i) => `<div class="card" data-i="${i}">
  <div class="card-images">${m.images.map(src =>
    `<img src="${src}" alt="" loading="lazy" decoding="async">`
  ).join('')}</div>
  <div class="card-body">
    <div class="card-title">
      <span>${esc(m.title)}${m.staffPick ? ' <span class="star" title="Staff pick">&#9733;</span>' : ''}</span>
      <span class="title-btns">
        <button class="fav-btn" title="Add to favorites">&#9825;</button>
        <button class="copy-btn">Copy Keywords</button>
      </span>
    </div>
    ${m.facets ? `<p class="facet-line">${FACET_KEYS.filter(k => m.facets[k] && m.facets[k] !== 'none').map(k =>
      `<span class="facet-chip" data-k="${k}" data-v="${m.facets[k]}" title="Filter by ${m.facets[k]}">${m.facets[k]}</span>`
    ).join(' &middot; ')}</p>` : ''}
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
const staffBox = document.getElementById('staffOnly');
const favBox = document.getElementById('favOnly');
const searchEl = document.getElementById('search');
const shuffleBtn = document.getElementById('shuffleBtn');
const showAllBtn = document.getElementById('showAllBtn');
const facetLabel = (k, v) => (k === 'subject' && v === 'none') ? 'style-only (any subject)' : v;
const facetSels = {};
FACET_KEYS.forEach(k => {
  const sel = document.getElementById('f-' + k);
  facetSels[k] = sel;
  const counts = {};
  DATA.forEach(m => { const v = m.facets && m.facets[k]; if (v) counts[v] = (counts[v] || 0) + 1; });
  Object.keys(counts).sort((a, b) => (a === 'none') - (b === 'none') || a.localeCompare(b)).forEach(v => {
    const o = document.createElement('option');
    o.value = v; o.textContent = `${facetLabel(k, v)} (${counts[v]})`;
    sel.appendChild(o);
  });
  sel.addEventListener('change', () => { sampleSet = null; render(); });
});
if (!DATA.some(m => m.facets)) document.getElementById('facetControls').style.display = 'none';

// ---- persistent state (favorites + prompt tray) ----
const store = (key, val) => { try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) {} };
const load = (key, fallback) => { try { return JSON.parse(localStorage.getItem(key)) || fallback; } catch (e) { return fallback; } };
const favs = new Set(load('krea-mb-favs', []));
let tray = load('krea-mb-tray', []);

// index pills by keyword so tray toggles don't scan 25K elements
const pillIndex = {};
grid.querySelectorAll('.pill').forEach(p => {
  (pillIndex[p.dataset.kw] = pillIndex[p.dataset.kw] || []).push(p);
});

// ---- filtering ----
let sampleSet = null;   // Set of card indices when in random-sample mode, null = show all matches

function currentMatches() {
  const q = searchEl.value.toLowerCase().trim();
  const staff = staffBox.checked;
  const fav = favBox.checked;
  const want = {};
  FACET_KEYS.forEach(k => { if (facetSels[k].value) want[k] = facetSels[k].value; });
  const wantKeys = Object.keys(want);
  const out = [];
  for (let i = 0; i < DATA.length; i++) {
    const m = DATA[i];
    if ((!q || hay[i].includes(q)) && (!staff || m.staffPick) && (!fav || favs.has(m.slug)) &&
        wantKeys.every(k => m.facets && m.facets[k] === want[k])) out.push(i);
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
    ? `Showing ${visible.length} random of ${matches.length} moodboards - shuffle for a new set, or search/filter to browse everything`
    : `Showing ${visible.length} of ${DATA.length} moodboards`;
}

shuffleBtn.addEventListener('click', () => { resample(); render(); window.scrollTo({top: 0}); });
showAllBtn.addEventListener('click', () => { sampleSet = null; render(); });
document.getElementById('clearBtn').addEventListener('click', () => {
  searchEl.value = ''; staffBox.checked = false; favBox.checked = false;
  FACET_KEYS.forEach(k => { facetSels[k].value = ''; });
  sampleSet = null; render();
});
let deb;
searchEl.addEventListener('input', () => { clearTimeout(deb); deb = setTimeout(() => { sampleSet = null; render(); }, 120); });
staffBox.addEventListener('change', () => { sampleSet = null; render(); });
favBox.addEventListener('change', () => { sampleSet = null; render(); });

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
    trayCopy.textContent = 'Copied!';
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
const lbCap = document.getElementById('lb-caption');
let lbBoard = 0, lbIdx = 0;
function lbShow() {
  const m = DATA[lbBoard];
  lbImg.src = m.images[lbIdx];
  lbCap.textContent = `${m.title} - image ${lbIdx + 1} of ${m.images.length}`;
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
    facetSels[t.dataset.k].value = t.dataset.v;
    sampleSet = null; render(); window.scrollTo({top: 0});
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
    if (favBox.checked) render();
    return;
  }
  if (t.classList.contains('copy-btn')) {
    navigator.clipboard.writeText(DATA[i].keywords).then(() => {
      t.textContent = 'Copied!';
      t.classList.add('copied');
      setTimeout(() => { t.textContent = 'Copy Keywords'; t.classList.remove('copied'); }, 1500);
    });
    return;
  }
  if (t.tagName === 'IMG' && t.closest('.card-images')) {
    lbOpen(i, [...t.parentElement.children].indexOf(t));
  }
});

resample();
render();
</script>
'@

$html = $html.Replace('__COUNT__', $count).Replace('__STAFF__', $staffCount).Replace('__DATA__', $dataJson).Replace('__BUILDDATE__', $buildDate)
$html | Out-File -Encoding utf8 $htmlOut
Write-Host "HTML: $htmlOut ($([math]::Round((Get-Item $htmlOut).Length/1MB,1)) MB)"

