# build-index.ps1 - checks every entry in islands\ and plans\ and writes index.json (the list the game reads).
# Run from anywhere: powershell -File tools\build-index.ps1   (Windows PowerShell 5.1 or PowerShell 7)
# An entry with a problem is left out of index.json and named in the output; the script then exits with code 1.
# -commit <sha>: the commit the entries' files are in (the GitHub workflow passes it). The game downloads every file
#   from that commit's fixed address, so the list and its files always match, even while GitHub's cache is catching up.
# -check: only check the entries, write nothing (for a pull request).
param([string]$commit = "", [switch]$check)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$maxIcon = 200KB; $maxPicture = 500KB; $maxEntry = 50MB
$entries = @(); $problems = @()

function Sha256([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($path)
    try { ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() } finally { $fs.Close() }
}
function Updated([string]$dir, [string]$fallback) {
    try { $d = (& git -C $root log -1 --format=%cs -- $dir 2>$null); if ($d) { return "$d".Trim() } } catch { }
    return $fallback
}

foreach ($kind in @("island", "plan")) {
    $folder = Join-Path $root ($kind + "s")
    if (-not (Test-Path $folder)) { continue }
    foreach ($dir in Get-ChildItem $folder -Directory | Sort-Object Name) {
        $id = $dir.Name; $bad = @()
        if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') { $bad += "the folder name must be lower case letters, digits and -" }
        $infoPath = Join-Path $dir.FullName "info.json"
        if (-not (Test-Path $infoPath)) { $problems += "$kind $id : no info.json"; continue }
        try { $info = Get-Content $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $problems += "$kind $id : info.json is not valid JSON ($($_.Exception.Message))"; continue }

        foreach ($f in @("kind", "title", "author", "version", "summary", "icon")) { if (-not $info.$f) { $bad += "info.json has no '$f'" } }
        if ($info.kind -and $info.kind -ne $kind) { $bad += "kind is '$($info.kind)' but the entry is in $($kind)s\" }
        $named = @($info.icon) + @($info.pictures | Where-Object { $_ })
        if ($kind -eq "plan") { if (-not $info.plan) { $bad += "info.json has no 'plan'" } else { $named += $info.plan } }
        foreach ($n in $named) { if (-not (Test-Path (Join-Path $dir.FullName $n))) { $bad += "'$n' is named in info.json but not in the folder" } }
        if ($info.icon -and (Test-Path (Join-Path $dir.FullName $info.icon)) -and (Get-Item (Join-Path $dir.FullName $info.icon)).Length -gt $maxIcon) { $bad += "the icon is over 200 KB" }
        foreach ($p in @($info.pictures | Where-Object { $_ })) { $pp = Join-Path $dir.FullName $p; if ((Test-Path $pp) -and (Get-Item $pp).Length -gt $maxPicture) { $bad += "'$p' is over 500 KB" } }

        $islands = @(Get-ChildItem $dir.FullName -Filter *.island)
        if ($islands.Count -eq 0) { $bad += "no .island file" }
        foreach ($i in $islands) {
            $head = New-Object byte[] 4; $fs = [IO.File]::OpenRead($i.FullName); try { [void]$fs.Read($head, 0, 4) } finally { $fs.Close() }
            if ([Text.Encoding]::ASCII.GetString($head) -ne "CISL") { $bad += "'$($i.Name)' is not an island file" }
        }
        if ($kind -eq "island" -and $islands.Count -gt 1) { $bad += "an island entry holds one .island file" }
        if ($kind -eq "plan" -and $info.plan -and (Test-Path (Join-Path $dir.FullName $info.plan))) {
            # every island the plan names must be in the folder (type: rules need none - the mod makes those islands)
            $names = @()
            foreach ($line in Get-Content (Join-Path $dir.FullName $info.plan) -Encoding UTF8) {
                if ($line -match '^\s*rule\s*=\s*[^|]*\|\s*island:([^|]+)\|') { $names += $Matches[1].Trim() }
                elseif ($line -match '^\s*rule\s*=\s*[^|]*\|\s*oneof:([^|]+)\|') { $names += ($Matches[1] -split ',' | ForEach-Object { $_.Trim() }) }
            }
            foreach ($n in $names | Sort-Object -Unique) { if (-not (Test-Path (Join-Path $dir.FullName ($n + ".island")))) { $bad += "the plan names island '$n' but '$n.island' is not in the folder" } }
        }

        # (names the game can download and store: no # % ? - they break a web address - and nothing Windows refuses)
        foreach ($f in Get-ChildItem $dir.FullName -File) {
            if ($f.Name -match '[#%?:*"<>|\\/]' -or $f.Name.StartsWith('.') -or $f.Name -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)\.') { $bad += "the file name '$($f.Name)' can't be downloaded by the game (no # % ? : * `" < > |)" }
        }
        $files = @(); $size = 0
        foreach ($f in Get-ChildItem $dir.FullName -File | Where-Object { $_.Name -ne "info.json" } | Sort-Object Name) {
            $files += [ordered]@{ name = $f.Name; size = $f.Length; sha256 = (Sha256 $f.FullName) }; $size += $f.Length
        }
        if ($size -gt $maxEntry) { $bad += "the entry is over 50 MB" }
        if ($bad.Count) { $problems += ($bad | ForEach-Object { "$kind $id : $_" }); continue }

        $e = [ordered]@{ id = $id; path = ($kind + "s/" + $id) }
        foreach ($p in $info.PSObject.Properties) { $e[$p.Name] = $p.Value }
        $e.islands = $islands.Count; $e.size = $size; $e.updated = (Updated $dir.FullName $info.created); $e.files = $files
        $entries += [pscustomobject]$e
    }
}

$sorted = @($entries | Sort-Object @{ Expression = { [bool]$_.featured }; Descending = $true }, @{ Expression = { $_.updated }; Descending = $true }, title)
$index = [ordered]@{
    format = 1
    library = "Custom Islands library"
    # (files: <download><path>/<name>; with a commit, from that commit - never changes; without, from main)
    download = "https://raw.githubusercontent.com/SwedenJohansson/CustomIslands-Library/" + $(if ($commit) { $commit } else { "main" }) + "/"
    commit = $commit
    entries = $sorted
}
if ($check) { "Checked: $($sorted.Count) good entr$(if ($sorted.Count -eq 1) { 'y' } else { 'ies' })" }
else {
    $json = $index | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $root "index.json"), $json + "`n", (New-Object Text.UTF8Encoding $false))
    "index.json: $($sorted.Count) entr$(if ($sorted.Count -eq 1) { 'y' } else { 'ies' })" + $(if ($commit) { " (files from commit $commit)" } else { "" })
}
if ($problems.Count) { "Left out:"; $problems | ForEach-Object { "  $_" }; exit 1 }
