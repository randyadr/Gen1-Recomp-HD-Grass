$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RemoteUrl = "https://github.com/randyadr/gen1recomp-grass-obj-replacer.git"
$RemoteWeb = "https://github.com/randyadr/gen1recomp-grass-obj-replacer"
$ManifestPath = Join-Path $RepoRoot "manifest.json"

Set-Location $RepoRoot

function Invoke-Git {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [switch]$AllowFailure
    )
    & git @Args
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "git $($Args -join ' ') failed with exit code $code"
    }
    return $code
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found. Install Git for Windows first, then run PUBLISH_UPDATE.bat again."
}

if (-not (Test-Path $ManifestPath)) {
    throw "manifest.json was not found in $RepoRoot"
}

Write-Host "Repository folder: $RepoRoot" -ForegroundColor Cyan

# A downloaded ZIP has no .git folder. Attach it to the real GitHub repository
# without deleting the files the user just overwrote locally.
if (-not (Test-Path (Join-Path $RepoRoot ".git"))) {
    Write-Host "No .git folder found. Linking this folder to GitHub..." -ForegroundColor Yellow
    Invoke-Git @("init") | Out-Null
    Invoke-Git @("branch", "-M", "main") | Out-Null
    Invoke-Git @("remote", "add", "origin", $RemoteUrl) | Out-Null

    # If main already exists remotely, anchor local history to it while keeping
    # the current working-tree files intact as the pending update.
    $fetchCode = Invoke-Git @("fetch", "origin", "main") -AllowFailure
    if ($fetchCode -eq 0) {
        & git show-ref --verify --quiet refs/remotes/origin/main
        if ($LASTEXITCODE -eq 0) {
            Invoke-Git @("reset", "origin/main") | Out-Null
        }
    }
} else {
    # Make sure origin points to the repo encoded in manifest.json.
    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git @("remote", "set-url", "origin", $RemoteUrl) | Out-Null
    } else {
        Invoke-Git @("remote", "add", "origin", $RemoteUrl) | Out-Null
    }
}

# Give Git a local identity if this machine has never been configured.
$name = (& git config user.name 2>$null)
if ([string]::IsNullOrWhiteSpace($name)) {
    Invoke-Git @("config", "user.name", "randyadr") | Out-Null
}
$email = (& git config user.email 2>$null)
if ([string]::IsNullOrWhiteSpace($email)) {
    Invoke-Git @("config", "user.email", "randyadr@users.noreply.github.com") | Out-Null
}

$statusBefore = (& git status --porcelain --untracked-files=all)
if ([string]::IsNullOrWhiteSpace(($statusBefore -join "`n"))) {
    Write-Host "There are no changed files to publish." -ForegroundColor Yellow
    Write-Host "Overwrite/update the mod files first, then run this again."
    exit 0
}

# Every published update needs a new semantic version so Gen1Recomp's updater
# can see it. Automatically increment x.y.Z -> x.y.(Z+1).
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$oldVersion = [string]$manifest.version
if ($oldVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
    throw "Version '$oldVersion' is not a simple x.y.z version. Update it manually."
}
$newVersion = "{0}.{1}.{2}" -f $Matches[1], $Matches[2], ([int]$Matches[3] + 1)
$manifest.version = $newVersion
$json = $manifest | ConvertTo-Json -Depth 32
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ManifestPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Version: $oldVersion -> $newVersion" -ForegroundColor Green

Invoke-Git @("add", "-A") | Out-Null
Invoke-Git @("commit", "-m", "Release v$newVersion") | Out-Null

Write-Host "Pushing to $RemoteUrl ..." -ForegroundColor Cyan
Invoke-Git @("push", "-u", "origin", "main") | Out-Null

Write-Host "" 
Write-Host "Pushed v$newVersion successfully." -ForegroundColor Green
Write-Host "GitHub Actions will create the release ZIP automatically from this push."
Write-Host "Actions: $RemoteWeb/actions"
Write-Host "Releases: $RemoteWeb/releases"
