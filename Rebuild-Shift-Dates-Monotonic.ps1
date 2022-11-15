<#
Rebuild-Shift-Dates-FINAL.ps1

Rewrite commit timestamps (preserve gaps, force author/email), stash local changes and
commit them dated StashOffsetDays after last rewritten commit.

USAGE example:
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  .\Rebuild-Shift-Dates-FINAL.ps1 -DesiredStart "2022-02-01T09:00:00" -Branch main `
    -NewName "Ehsan Akbari" -NewEmail "ehsanakbari.dev@gmail.com" -StashOffsetDays 7
#>

[CmdletBinding()]
param(
    [string]$DesiredStart = "2022-02-01T09:00:00",
    [string]$Branch = "main",
    [string]$NewName = "Ehsan Akbari",
    [string]$NewEmail = "ehsanakbari.dev@gmail.com",
    [string]$Remote = "origin",
    [int]$StashOffsetDays = 7
)

function Abort($msg) {
    Write-Error $msg
    exit 1
}

Write-Host "=== Rebuild-Shift-Dates-FINAL starting ===" -ForegroundColor Cyan

# basic checks
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Abort "git not found in PATH. Install Git for Windows." }
try { git rev-parse --is-inside-work-tree 2>$null | Out-Null } catch { Abort "Not a git repository (run in repo root)." }

$repoRoot = (git rev-parse --show-toplevel).Trim()
Write-Host "Repository root: $repoRoot"

# mirror backup
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path (Split-Path $repoRoot -Parent) ((Split-Path $repoRoot -Leaf) + "-mirror-$timestamp.git")
Write-Host "Creating local bare mirror backup at: $backupDir"
git clone --mirror . $backupDir | Out-Null
if ($LASTEXITCODE -ne 0) { Abort "mirror clone failed. Aborting." }
Write-Host "Mirror backup created."

# ensure branch exists (fetch if needed)
$branchExists = $false
try {
    git rev-parse --verify $Branch 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $branchExists = $true }
} catch { $branchExists = $false }

if (-not $branchExists) {
    Write-Host "Local branch '$Branch' not found. Trying to fetch from remote '$Remote'..."
    $refspec = $Branch + ":" + $Branch
    git fetch $Remote $refspec
    if ($LASTEXITCODE -ne 0) { Abort "Could not fetch branch $Branch from $Remote" }
}

# gather commits oldest->newest
Write-Host "Gathering commits on branch '$Branch'..."
$commits = git rev-list --reverse $Branch 2>$null | ForEach-Object { $_.Trim() }
if (-not $commits -or $commits.Count -eq 0) { Abort "No commits found on branch $Branch" }

# read original timestamps
$origTimestamps = @()
foreach ($c in $commits) {
    $t = [int](git show -s --format=%ct $c)
    $origTimestamps += $t
}

# parse desired start (UTC epoch seconds)
try {
    $desiredDt = [DateTime]::Parse($DesiredStart)
} catch { Abort "Failed to parse DesiredStart. Use ISO-like string e.g. 2022-02-01T09:00:00" }
$desiredUtc = $desiredDt.ToUniversalTime()
$desiredStartTs = [int]([double]($desiredUtc - [DateTime]'1970-01-01').TotalSeconds)

# build monotonic timestamps preserving gaps
$newTimestamps = @()
for ($i=0; $i -lt $origTimestamps.Count; $i++) {
    if ($i -eq 0) {
        $newTimestamps += $desiredStartTs
    } else {
        $delta = $origTimestamps[$i] - $origTimestamps[$i-1]
        if ($delta -lt 0) { $delta = 0 }
        $newTimestamps += ($newTimestamps[$i-1] + $delta)
    }
}

Write-Host "Original first ts: $($origTimestamps[0])"
Write-Host "Desired start ts: $desiredStartTs (UTC: $($desiredUtc.ToString("u")))"
Write-Host "Prepared $($commits.Count) new timestamps."

# build env-filter file (ASCII, no BOM) - avoid PowerShell interpolation by using single-quoted literals where needed
$envFile = Join-Path $env:TEMP ("git_env_filter_final_$timestamp.sh")
$lines = @()
$lines += '#!/usr/bin/env bash'
$lines += 'case "$GIT_COMMIT" in'

# escape name/email double quotes
$escapedName = $NewName -replace '"','\"'
$escapedEmail = $NewEmail -replace '"','\"'

for ($i=0; $i -lt $commits.Count; $i++) {
    $c = $commits[$i]
    $newTs = [int]$newTimestamps[$i]
    $newDate = (Get-Date ([DateTime]'1970-01-01').AddSeconds($newTs).ToUniversalTime()).ToString("r")
    $escapedDate = $newDate -replace '"','\"'

    # append lines (use concatenation to include PowerShell variables safely)
    $lines += ('  ' + $c + ')')
    $lines += ('    export GIT_AUTHOR_NAME="' + $escapedName + '"')
    $lines += ('    export GIT_AUTHOR_EMAIL="' + $escapedEmail + '"')
    $lines += ('    export GIT_COMMITTER_NAME="' + $escapedName + '"')
    $lines += ('    export GIT_COMMITTER_EMAIL="' + $escapedEmail + '"')
    $lines += ('    export GIT_AUTHOR_DATE="' + $escapedDate + '"')
    $lines += ('    export GIT_COMMITTER_DATE="' + $escapedDate + '"')
    $lines += '    ;;'
}

$lines += '  *)'
$lines += ('    export GIT_AUTHOR_NAME="' + $escapedName + '"')
$lines += ('    export GIT_AUTHOR_EMAIL="' + $escapedEmail + '"')
$lines += ('    export GIT_COMMITTER_NAME="' + $escapedName + '"')
$lines += ('    export GIT_COMMITTER_EMAIL="' + $escapedEmail + '"')
$lines += '    ;;'
$lines += 'esac'

# write file ASCII (no BOM) to avoid /usr/bin/env errors on Git Bash
$lines -join "`n" | Set-Content -Path $envFile -Encoding ASCII -Force
Write-Host "Env filter written (no BOM): $envFile"

# stash uncommitted changes if any
$stashed = $false
$hasUncommitted = $false
git diff --quiet 2>$null; if ($LASTEXITCODE -ne 0) { $hasUncommitted = $true }
git diff --cached --quiet 2>$null; if ($LASTEXITCODE -ne 0) { $hasUncommitted = $true }

if ($hasUncommitted) {
    Write-Host "Stashing uncommitted changes..."
    git add -A
    git stash push -m "temp-before-rewrite-$timestamp" | Out-Null
    if ($LASTEXITCODE -ne 0) { Abort "git stash failed." }
    $stashed = $true
    Write-Host "Stashed."
} else {
    Write-Host "No uncommitted changes."
}

# try to add Git Bash common dirs to PATH for this session
$possibleDirs = @(
    "$env:ProgramFiles\Git\bin",
    "$env:ProgramFiles\Git\usr\bin",
    "$env:ProgramFiles(x86)\Git\bin",
    "$env:ProgramFiles(x86)\Git\usr\bin"
)
foreach ($d in $possibleDirs) {
    if ($d -and (Test-Path (Join-Path $d "bash.exe"))) {
        $env:PATH = $d + ";" + $env:PATH
        Write-Host "Temporarily added Git Bash dir to PATH: $d"
        break
    }
}
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Warning "bash not found in PATH. Install Git for Windows (Git Bash). Script will still try but may fail."
}

# prepare posix path and run git filter-branch under bash
$envFilePosix = $envFile -replace '\\','/'
if ($envFilePosix -match '^[A-Za-z]:') {
    $drive = $envFilePosix.Substring(0,1).ToLower()
    $envFilePosix = '/' + $drive + $envFilePosix.Substring(2)
}

$bashCmd = "cp '$envFilePosix' /tmp/git_env_filter.sh && chmod +x /tmp/git_env_filter.sh && git filter-branch -f --env-filter 'source /tmp/git_env_filter.sh' -- --all"
Write-Host "Running under bash: $bashCmd"

try {
    & bash -lc $bashCmd
    if ($LASTEXITCODE -ne 0) { Abort "git filter-branch failed (exit=$LASTEXITCODE). Restore from: $backupDir" }
} catch {
    Abort "Could not run bash/git filter-branch. Ensure Git Bash installed and in PATH."
}

Write-Host "git filter-branch finished."

# if we stashed, pop and commit with offset days after last new commit
if ($stashed) {
    Write-Host "Restoring stash (git stash pop)..."
    git stash pop
    if ($LASTEXITCODE -ne 0) { Abort "git stash pop failed or conflicts occurred. Resolve manually." }

    git add -A

    $lastNewTs = $newTimestamps[-1]
    $offsetSeconds = [int]($StashOffsetDays * 86400)
    if ($offsetSeconds -eq 0) { $offsetSeconds = 60 }
    $stashTs = $lastNewTs + $offsetSeconds
    $stashDate = (Get-Date ([DateTime]'1970-01-01').AddSeconds($stashTs).ToUniversalTime()).ToString("r")

    Write-Host "Committing stash as: $stashDate"
    $env:GIT_AUTHOR_NAME = $NewName
    $env:GIT_AUTHOR_EMAIL = $NewEmail
    $env:GIT_COMMITTER_NAME = $NewName
    $env:GIT_COMMITTER_EMAIL = $NewEmail
    $env:GIT_AUTHOR_DATE = $stashDate
    $env:GIT_COMMITTER_DATE = $stashDate

    git commit -m "Update readme.md" 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Nothing to commit after stash pop (maybe stash empty)." }

    # cleanup env vars
    Remove-Item Env:\GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
    Remove-Item Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
    Remove-Item Env:\GIT_AUTHOR_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\GIT_AUTHOR_EMAIL -ErrorAction SilentlyContinue
    Remove-Item Env:\GIT_COMMITTER_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\GIT_COMMITTER_EMAIL -ErrorAction SilentlyContinue

    Write-Host "Stashed changes committed."
}

# cleanup refs/original and gc
Write-Host "Cleaning refs/original and running git gc..."
try {
    git for-each-ref --format="%(refname)" refs/original/ | ForEach-Object { git update-ref -d $_ }
} catch { Write-Warning "Failed to delete refs/original; continuing." }

git reflog expire --expire=now --all 2>$null | Out-Null
git gc --prune=now --aggressive 2>$null | Out-Null

# remove env file
Remove-Item -Force $envFile -ErrorAction SilentlyContinue

Write-Host "`n=== Local rewriting complete ===" -ForegroundColor Green
Write-Host "Mirror backup: $backupDir"
Write-Host "Check logs:"
Write-Host "  git log --pretty=format:'%h %ct %ad %an <%ae>' --date=iso --reverse $Branch | more"
Write-Host "If OK, force-push:"
Write-Host "  git push $Remote --force --all"
Write-Host "  git push $Remote --force --tags"
Write-Host "IMPORTANT: After force-push collaborators must reclone or reset."
Write-Host "== Done ==" -ForegroundColor Cyan
