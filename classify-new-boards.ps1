# classify-new-boards.ps1
# Facet-classifies moodboards that a crawl added but that have no entry yet in
# krea2-moodboard-facets.json, using the same dual-vote + arbiter method that
# produced the original labels (see README.md "Facet classification"):
#   1. two independent votes per batch (claude -p, $VoterModel)
#   2. facet-exact agreement -> source: consensus
#   3. any disagreement -> $ArbiterModel sees both votes and decides all four facets
#
# Results are APPENDED to krea2-moodboard-facets.json after EVERY batch, so an
# interrupted run (usage cap, network, Ctrl+C) loses at most one batch; re-running
# skips everything already classified.
#
# Requires the `claude` CLI (Claude Code) on PATH, logged in.
#
# Usage:
#   ./classify-new-boards.ps1                # classify whatever is unlabeled, then rebuild html
#   ./classify-new-boards.ps1 -NoRebuild     # classify only
#   ./classify-new-boards.ps1 -BatchSize 25  # smaller batches

param(
    [int]$BatchSize = 50,
    [string]$VoterModel = 'haiku',
    [string]$ArbiterModel = 'sonnet',
    [string]$DocsDir = $PSScriptRoot,
    [switch]$NoRebuild
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$jsonPath   = Join-Path $DocsDir 'krea2-moodboards.json'
$facetsPath = Join-Path $DocsDir 'krea2-moodboard-facets.json'
if (-not (Test-Path $jsonPath)) { throw "catalog not found: $jsonPath" }

$catalog = Get-Content $jsonPath -Raw | ConvertFrom-Json
$facets  = if (Test-Path $facetsPath) { @(Get-Content $facetsPath -Raw | ConvertFrom-Json) } else { @() }
$known = @{}; $facets | ForEach-Object { $known[$_.slug] = $true }
$todo = @($catalog | Where-Object { -not $known.ContainsKey($_.slug) })
if (-not $todo.Count) { Write-Host 'Nothing to classify - every board already has facets.'; exit 0 }
Write-Host "Boards to classify: $($todo.Count) (batches of $BatchSize, voter=$VoterModel, arbiter=$ArbiterModel)"

$vocab = [ordered]@{
    medium  = @('film-photography','studio-photography','painting','illustration','print-craft','digital-art','collage','graphic-design')
    mood    = @('noir','ethereal-dreamy','nostalgic-retro','surreal','minimalist-serene','gritty-industrial','gothic-dark','cozy-folk','vibrant-energetic','cosmic-mystical')
    palette = @('monochrome','cobalt-blue','crimson-red','amber-gold','teal-emerald','neon','pastel','earth-tones','full-color')
    subject = @('portrait','figure-motion','landscape','urban','nature-botanical','abstract','character-design','none')
}
$FACET_KEYS = @('medium','mood','palette','subject')

$rulesText = @"
You classify image style moodboards into four facets. Use EXACTLY these values:
medium: $($vocab.medium -join ' | ')
mood: $($vocab.mood -join ' | ')
palette: $($vocab.palette -join ' | ')
subject: $($vocab.subject -join ' | ')

Tie-break rules (mandatory):
- Mood: if the TITLE contains a mood word (nostalgic, ethereal, surreal, noir, gothic, celestial, cosmic, cozy, whimsical, minimalist, gritty, vibrant, kinetic, dreamy, serene, ...), that register wins; if several, the first such word in the title wins. Titles are the curator's own signal.
- Palette: monochrome is strictly achromatic (black/white/gray only). A single hue plus black/white belongs to that hue's family. Accent colors never change the base palette.
- Subject: assign a subject ONLY when the title or a keyword explicitly names a depicted subject; otherwise use none. Do not infer subjects from style words.

Reply with ONLY a raw JSON array, no markdown fences, no commentary:
[{"slug":"...","medium":"...","mood":"...","palette":"...","subject":"..."}]
Include exactly one object per input board, using the input slugs verbatim.
"@

function Invoke-Claude([string]$Prompt, [string]$Model) {
    $out = $Prompt | claude -p --model $Model
    if ($LASTEXITCODE -ne 0) { throw "claude CLI failed (exit $LASTEXITCODE)" }
    return ($out -join "`n")
}

# Returns slug->record hashtable, or $null if the reply is unparseable/invalid/incomplete
function ConvertTo-VoteMap([string]$Text, [string[]]$ExpectedSlugs) {
    $m = [regex]::Match($Text, '\[[\s\S]*\]')
    if (-not $m.Success) { return $null }
    try { $arr = @($m.Value | ConvertFrom-Json) } catch { return $null }
    $map = @{}
    foreach ($rec in $arr) {
        if (-not $rec.slug) { return $null }
        foreach ($k in $FACET_KEYS) {
            if ($vocab[$k] -notcontains $rec.$k) { return $null }
        }
        $map[$rec.slug] = $rec
    }
    foreach ($s in $ExpectedSlugs) { if (-not $map.ContainsKey($s)) { return $null } }
    return $map
}

function Get-ValidatedVote([string]$Prompt, [string]$Model, [string[]]$ExpectedSlugs, [string]$Label) {
    foreach ($attempt in 1..3) {
        $map = ConvertTo-VoteMap (Invoke-Claude $Prompt $Model) $ExpectedSlugs
        if ($map) { return $map }
        Write-Host "    $Label attempt $attempt invalid, retrying..."
    }
    return $null
}

$failLog = Join-Path $env:TEMP 'moodboard-classify-failures.txt'
if (Test-Path $failLog) { Remove-Item $failLog }
$appended = 0
$batchNum = 0
$totalBatches = [Math]::Ceiling($todo.Count / $BatchSize)

for ($ofs = 0; $ofs -lt $todo.Count; $ofs += $BatchSize) {
    $batchNum++
    $batch = @($todo[$ofs..([Math]::Min($ofs + $BatchSize, $todo.Count) - 1)])
    $slugs = @($batch | ForEach-Object { $_.slug })
    $lines = ($batch | ForEach-Object { "$($_.slug) | $($_.title) | $($_.keywords) | $($_.profile)" }) -join "`n"
    $votePrompt = "$rulesText`nBoards (slug | title | keywords | taste profile):`n$lines"

    Write-Host "  batch $batchNum/${totalBatches}: $($batch.Count) boards"
    $voteA = Get-ValidatedVote $votePrompt $VoterModel $slugs 'vote A'
    $voteB = Get-ValidatedVote $votePrompt $VoterModel $slugs 'vote B'
    if (-not $voteA -or -not $voteB) {
        Add-Content $failLog "batch ${batchNum}: voting failed for slugs: $($slugs -join ', ')"
        Write-Warning "  batch ${batchNum}: voting failed, skipping (logged)"
        continue
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $disputed = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $batch) {
        $a = $voteA[$b.slug]; $c = $voteB[$b.slug]
        $agree = -not @($FACET_KEYS | Where-Object { $a.$_ -ne $c.$_ }).Count
        if ($agree) {
            $records.Add([pscustomobject]@{ slug = $b.slug; medium = $a.medium; mood = $a.mood; palette = $a.palette; subject = $a.subject; source = 'consensus' })
        } else {
            $disputed.Add([pscustomobject]@{ board = $b; a = $a; b2 = $c })
        }
    }

    if ($disputed.Count) {
        $dLines = ($disputed | ForEach-Object {
            $bd = $_.board
            "$($bd.slug) | $($bd.title) | $($bd.keywords) | $($bd.profile)`n  vote A: $(($_.a | Select-Object medium,mood,palette,subject | ConvertTo-Json -Compress))`n  vote B: $(($_.b2 | Select-Object medium,mood,palette,subject | ConvertTo-Json -Compress))"
        }) -join "`n"
        $arbPrompt = "$rulesText`nTwo independent classifiers disagreed on the boards below. Weigh both votes against the full context and the tie-break rules, then decide ALL FOUR facets for each board.`n`n$dLines"
        $dSlugs = @($disputed | ForEach-Object { $_.board.slug })
        $arb = Get-ValidatedVote $arbPrompt $ArbiterModel $dSlugs 'arbiter'
        if ($arb) {
            foreach ($s in $dSlugs) {
                $r = $arb[$s]
                $records.Add([pscustomobject]@{ slug = $s; medium = $r.medium; mood = $r.mood; palette = $r.palette; subject = $r.subject; source = 'arbiter' })
            }
        } else {
            Add-Content $failLog "batch ${batchNum}: arbiter failed for slugs: $($dSlugs -join ', ')"
            Write-Warning "  batch ${batchNum}: arbiter failed for $($dSlugs.Count) boards (logged); consensus boards still saved"
        }
    }

    if ($records.Count) {
        # re-read + append + write after every batch so interrupted runs lose nothing
        $current = if (Test-Path $facetsPath) { @(Get-Content $facetsPath -Raw | ConvertFrom-Json) } else { @() }
        $current + $records | ConvertTo-Json -Depth 3 -Compress | Out-File -Encoding utf8 $facetsPath
        $appended += $records.Count
        $arbCount = @($records | Where-Object source -eq 'arbiter').Count
        Write-Host "    saved $($records.Count) ($($records.Count - $arbCount) consensus, $arbCount arbiter) - total appended: $appended"
    }
}

Write-Host "Done: $appended classifications appended to $facetsPath"
if (Test-Path $failLog) { Write-Warning "Some boards failed - see $failLog" }

if ($appended -and -not $NoRebuild) {
    $build = Join-Path $DocsDir 'build-moodboard-catalog.ps1'
    if (Test-Path $build) {
        $raw = Join-Path $env:TEMP 'krea-moodboards-raw.json'
        Write-Host 'Rebuilding catalog + html with new facets...'
        if (Test-Path $raw) { & $build -SkipImages -RawJson $raw } else { & $build -SkipImages }
    } else {
        Write-Host "build-moodboard-catalog.ps1 not found in $DocsDir - skipping rebuild"
    }
}
