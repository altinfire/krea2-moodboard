# classify-mood-registers.ps1
# Pass-2 mood refinement for the fat buckets (noir, ethereal-dreamy) — see taxonomy-mood.md.
# For each board: two independent voters re-judge the TOP-LEVEL mood (fresh, all 10 values,
# original tie-break rule) AND assign a moodDetail "register" from a shared, support-gated
# vocabulary (null allowed and expected). Facet-exact agreement -> consensus; any
# disagreement, or a consensus mood that flips the pass-1 label, goes to the arbiter
# (which sees both votes and the pass-1 mood). This doubles as the accuracy pass.
#
# Results are APPENDED to krea2-moodboard-mood-registers.json after EVERY batch, so an
# interrupted run (usage cap, Ctrl+C, session death) loses at most one batch; re-running
# skips already-classified slugs. The original krea2-moodboard-facets.json is NOT touched —
# merging moodDetail into the catalog/build is a separate, cheap local step once reviewed.
#
# Usage gate: before each batch the script runs `node ~/.claude/check-usage.js` and stops
# cleanly once the 5-hour window reaches -UsageCap percent (default 80). If the usage
# check is unparseable the script stops too (fail-safe); -SkipUsageGate overrides.
#
# Usage:
#   ./classify-mood-registers.ps1                 # gated full run
#   ./classify-mood-registers.ps1 -MaxBatches 1   # smoke-test one batch
#   ./classify-mood-registers.ps1 -UsageCap 70    # stop earlier

param(
    [int]$BatchSize = 50,
    [string]$VoterModel = 'haiku',
    [string]$ArbiterModel = 'sonnet',
    [int]$UsageCap = 80,
    [int]$MaxBatches = 0,
    [string]$DocsDir = $PSScriptRoot,
    [switch]$SkipUsageGate
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$jsonPath = Join-Path $DocsDir 'krea2-moodboards.json'
$outPath  = Join-Path $DocsDir 'krea2-moodboard-mood-registers.json'
if (-not (Test-Path $jsonPath)) { throw "catalog not found: $jsonPath" }

$MOODS = @('noir','ethereal-dreamy','nostalgic-retro','surreal','minimalist-serene','gritty-industrial','gothic-dark','cozy-folk','vibrant-energetic','cosmic-mystical')
$ALLOW = @{
    'noir'            = @('nocturnal','spectral','kinetic','luminous','minimal','glitch','chiaroscuro','liminal')
    'ethereal-dreamy' = @('nocturnal','spectral','kinetic','luminous','minimal','liminal','twilight','painterly')
}

$catalog = Get-Content $jsonPath -Raw | ConvertFrom-Json
$done = @{}
if (Test-Path $outPath) { @(Get-Content $outPath -Raw | ConvertFrom-Json) | ForEach-Object { $done[$_.slug] = $true } }
$todo = @($catalog | Where-Object { $_.facets -and $_.facets.mood -in $ALLOW.Keys -and -not $done.ContainsKey($_.slug) })
if (-not $todo.Count) { Write-Host 'Nothing to classify - all fat-bucket boards already have pass-2 records.'; exit 0 }
$totalBatches = [Math]::Ceiling($todo.Count / $BatchSize)
Write-Host "Boards to classify: $($todo.Count) ($totalBatches batches of $BatchSize, voter=$VoterModel, arbiter=$ArbiterModel, usage cap $UsageCap%)"

$rulesText = @"
You classify image style moodboards. For EACH board emit two fields:

1. "mood" — exactly one of:
   $($MOODS -join ' | ')
   Tie-break (mandatory): if the TITLE contains a mood word (nostalgic, ethereal, surreal,
   noir, gothic, celestial, cosmic, cozy, whimsical, minimalist, gritty, vibrant, kinetic,
   dreamy, serene, ...), that register wins; if several, the first such word in the title
   wins. Titles are the curator's own signal.

2. "moodDetail" — a stylistic register WITHIN the mood, or null. Allowed values depend on mood:
   noir: nocturnal | spectral | kinetic | luminous | minimal | glitch | chiaroscuro | liminal
   ethereal-dreamy: nocturnal | spectral | kinetic | luminous | minimal | liminal | twilight | painterly
   any other mood: always null
   Definitions:
   - nocturnal: night-set imagery (night, nocturne, midnight, moonlit)
   - spectral: ghostly, apparitional, phantom presences (spectral, haunted, abyssal)
   - kinetic: motion as the technique — motion blur, long exposure, intentional camera movement, shutter drag
   - luminous: glow-driven — luminescence, bioluminescence, radiant light sources
   - minimal: stark reduction — graphic silhouettes, brutalist or geometric austerity
   - glitch: digital corruption — glitch art, pixel sorting, CRT/scanline/VHS artifacts
   - chiaroscuro: classic studio light-shadow drama as the board's stated identity (title-level chiaroscuro/shadowplay)
   - liminal: liminal spaces — empty transitional places, eerie vacancy
   - twilight: dusk, blue hour, fading golden light
   - painterly: impressionist/painterly rendering as the register (regardless of medium)
   Assign a register ONLY when the title or a keyword clearly evidences it; otherwise use
   null. Null is a normal, expected answer — do not force a register. "Cinematic" is NOT a
   register; boards that are simply cinematic get null. If several registers match, the one
   named in the title wins; first title mention wins.

Reply with ONLY a raw JSON array, no markdown fences, no commentary:
[{"slug":"...","mood":"...","moodDetail":"..."|null}]
Include exactly one object per input board, using the input slugs verbatim.
"@

function Invoke-Claude([string]$Prompt, [string]$Model) {
    $out = $Prompt | claude -p --model $Model
    if ($LASTEXITCODE -ne 0) { throw "claude CLI failed (exit $LASTEXITCODE)" }
    return ($out -join "`n")
}

# slug->record map, or $null if unparseable/invalid/incomplete.
# moodDetail is normalized: ''/'none'/'null' -> $null; a register that is not allowed for
# the record's mood is coerced to $null (robustness) rather than failing the whole vote.
function ConvertTo-VoteMap([string]$Text, [string[]]$ExpectedSlugs) {
    $m = [regex]::Match($Text, '\[[\s\S]*\]')
    if (-not $m.Success) { return $null }
    try { $arr = @($m.Value | ConvertFrom-Json) } catch { return $null }
    $map = @{}
    foreach ($rec in $arr) {
        if (-not $rec.slug) { return $null }
        if ($MOODS -notcontains $rec.mood) { return $null }
        $d = $rec.moodDetail
        if ($d -is [string] -and $d.Trim().ToLower() -in @('', 'none', 'null')) { $d = $null }
        if ($null -ne $d) {
            if (-not $ALLOW.ContainsKey($rec.mood) -or $ALLOW[$rec.mood] -notcontains $d) { $d = $null }
        }
        $map[$rec.slug] = [pscustomobject]@{ slug = $rec.slug; mood = $rec.mood; moodDetail = $d }
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

function Get-UsagePct {
    try { $out = (node "$HOME\.claude\check-usage.js" 2>&1 | Out-String) } catch { return -1 }
    if ($out -match '5-hour window:\s+(\d+)%') { return [int]$Matches[1] }
    return -1
}

$failLog = Join-Path $env:TEMP 'mood-register-failures.txt'
if (Test-Path $failLog) { Remove-Item $failLog -Confirm:$false }
$appended = 0; $flips = 0; $batchNum = 0

for ($ofs = 0; $ofs -lt $todo.Count; $ofs += $BatchSize) {
    if ($MaxBatches -and $batchNum -ge $MaxBatches) { Write-Host "MaxBatches ($MaxBatches) reached - stopping."; break }
    if (-not $SkipUsageGate) {
        $pct = Get-UsagePct
        if ($pct -lt 0) { Write-Warning 'Usage check unparseable - stopping (fail-safe). Use -SkipUsageGate to override.'; break }
        if ($pct -ge $UsageCap) { Write-Host "Usage gate: 5-hour window at $pct% >= cap $UsageCap% - stopping cleanly. Re-run later to resume."; break }
        Write-Host "  [usage $pct%]"
    }
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
        $prev = $b.facets.mood
        $agree = ($a.mood -eq $c.mood) -and ($a.moodDetail -eq $c.moodDetail)
        if ($agree -and $a.mood -eq $prev) {
            $records.Add([pscustomobject]@{ slug = $b.slug; mood = $a.mood; moodDetail = $a.moodDetail; source = 'consensus'; pass = 2 })
        } else {
            # voter split, or unanimous mood-flip vs pass 1 -> arbiter sees everything
            $disputed.Add([pscustomobject]@{ board = $b; a = $a; b2 = $c; prev = $prev })
        }
    }

    if ($disputed.Count) {
        $dLines = ($disputed | ForEach-Object {
            $bd = $_.board
            "$($bd.slug) | $($bd.title) | $($bd.keywords) | $($bd.profile)`n  pass-1 mood: $($_.prev)`n  vote A: $(($_.a | Select-Object mood,moodDetail | ConvertTo-Json -Compress))`n  vote B: $(($_.b2 | Select-Object mood,moodDetail | ConvertTo-Json -Compress))"
        }) -join "`n"
        $arbPrompt = "$rulesText`nTwo independent classifiers assessed the boards below; their votes and the earlier pass-1 mood label are shown. Weigh all signals against the rules, then decide the final mood AND moodDetail for each board. Overturn the pass-1 mood only when the evidence clearly supports it.`n`n$dLines"
        $dSlugs = @($disputed | ForEach-Object { $_.board.slug })
        $arb = Get-ValidatedVote $arbPrompt $ArbiterModel $dSlugs 'arbiter'
        if ($arb) {
            foreach ($d in $disputed) {
                $r = $arb[$d.board.slug]
                $rec = [ordered]@{ slug = $d.board.slug; mood = $r.mood; moodDetail = $r.moodDetail; source = 'arbiter'; pass = 2 }
                if ($r.mood -ne $d.prev) { $rec.prevMood = $d.prev; $flips++ }
                $records.Add([pscustomobject]$rec)
            }
        } else {
            Add-Content $failLog "batch ${batchNum}: arbiter failed for slugs: $($dSlugs -join ', ')"
            Write-Warning "  batch ${batchNum}: arbiter failed for $($dSlugs.Count) boards (logged); consensus boards still saved"
        }
    }

    if ($records.Count) {
        $current = if (Test-Path $outPath) { @(Get-Content $outPath -Raw | ConvertFrom-Json) } else { @() }
        $current + $records | ConvertTo-Json -Depth 3 -Compress | Out-File -Encoding utf8 $outPath
        $appended += $records.Count
        $arbCount = @($records | Where-Object source -eq 'arbiter').Count
        $regCount = @($records | Where-Object { $_.moodDetail }).Count
        Write-Host "    saved $($records.Count) ($($records.Count - $arbCount) consensus, $arbCount arbiter; $regCount with a register) - total: $appended, mood flips so far: $flips"
    }
}

Write-Host "Done this run: $appended records in $outPath (mood flips: $flips)"
if (Test-Path $failLog) { Write-Warning "Some boards failed - see $failLog" }
