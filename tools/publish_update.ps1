$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Owner = "randyadr"
$RepoName = "Gen1-Recomp-HD-Grass"
$Repo = "$Owner/$RepoName"
$RemoteUrl = "https://github.com/$Repo.git"
$ManifestPath = Join-Path $RepoRoot "manifest.json"
$FirstSetup = Join-Path $PSScriptRoot "first_time_setup.ps1"

Set-Location $RepoRoot

function Git {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
    & git @Args
    if ($LASTEXITCODE -ne 0) { throw "git $($Args -join ' ') failed." }
}

function Ensure-ToolsAndLogin {
    if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FirstSetup -ToolsOnly
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    & gh auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub login is required. Opening browser login..." -ForegroundColor Yellow
        & gh auth login --hostname github.com --web --git-protocol https
        if ($LASTEXITCODE -ne 0) { throw "GitHub login failed." }
    }
}

Ensure-ToolsAndLogin

$login = (& gh api user --jq .login 2>$null | Select-Object -First 1).Trim()
if ($login -ne $Owner) {
    & gh auth switch --hostname github.com --user $Owner
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI must be logged in as '$Owner'." }
}

# The target repo already exists. If this folder came from a downloaded ZIP,
# attach it to origin/main without replacing the working files we just unpacked.
if (-not (Test-Path (Join-Path $RepoRoot ".git"))) {
    Write-Host "No .git folder found. Attaching this ZIP folder to $Repo..." -ForegroundColor Cyan
    Git init
    Git branch -M main
    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) { Git remote set-url origin $RemoteUrl } else { Git remote add origin $RemoteUrl }
    & git fetch origin main
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch existing $Repo main branch." }
    # Mixed reset attaches HEAD/index to the existing GitHub history while
    # intentionally leaving all new combined-mod working files untouched.
    Git reset origin/main
} else {
    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) { Git remote set-url origin $RemoteUrl } else { Git remote add origin $RemoteUrl }
    & git fetch origin main *> $null
    if ($LASTEXITCODE -eq 0) {
        & git pull --rebase --autostash origin main
        if ($LASTEXITCODE -ne 0) { throw "Could not update from origin/main." }
    }
}

if ([string]::IsNullOrWhiteSpace((& git config user.name 2>$null))) { Git config user.name $Owner }
if ([string]::IsNullOrWhiteSpace((& git config user.email 2>$null))) { Git config user.email "$Owner@users.noreply.github.com" }

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ([string]$manifest.github -ne $Repo) { throw "manifest github field must be '$Repo'." }
$modId = [string]$manifest.id
$currentVersion = [string]$manifest.version
if ($currentVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "Version '$currentVersion' is not x.y.z." }
$versionParts = $currentVersion.Split('.')
$versionMajor = [int]$versionParts[0]
$versionMinor = [int]$versionParts[1]
$versionPatch = [int]$versionParts[2]

# First publish of the combined mod: keep its current version if that exact
# release asset does not exist yet. Later publishes auto-bump the patch version.
$currentTag = "v$currentVersion"
$currentAsset = "$modId-$currentVersion.zip"
$releaseExists = $false
& gh release view $currentTag -R $Repo --json assets --jq ".assets[].name" 2>$null | ForEach-Object {
    if ($_.Trim() -eq $currentAsset) { $releaseExists = $true }
}

if ($releaseExists) {
    $oldVersion = $currentVersion
    $newVersion = "{0}.{1}.{2}" -f $versionMajor, $versionMinor, ($versionPatch + 1)
    $manifest.version = $newVersion
    $json = $manifest | ConvertTo-Json -Depth 32
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ManifestPath, $json + [Environment]::NewLine, $utf8NoBom)
    Write-Host "Version: $oldVersion -> $newVersion" -ForegroundColor Green
} else {
    $newVersion = $currentVersion
    Write-Host "First combined release: keeping version $newVersion" -ForegroundColor Green
}

$status = (& git status --porcelain --untracked-files=all)
if ([string]::IsNullOrWhiteSpace(($status -join "`n"))) {
    Write-Host "There are no changed files to publish." -ForegroundColor Yellow
    exit 0
}

Git add -A
Git commit -m "Release v$newVersion"
Git push -u origin main

# Wait for the push-triggered release workflow and verify the release asset.
Start-Sleep -Seconds 3
$runId = $null
for ($i = 0; $i -lt 25; $i++) {
    $runId = (& gh run list -R $Repo --workflow release.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null | Select-Object -First 1).Trim()
    if ($runId) { break }
    Start-Sleep -Seconds 2
}
if (-not $runId) { throw "Push succeeded, but no GitHub Actions release run appeared." }

Write-Host "Waiting for GitHub Actions release run $runId..." -ForegroundColor Cyan
& gh run watch $runId -R $Repo --exit-status
if ($LASTEXITCODE -ne 0) { throw "GitHub Actions release workflow failed." }

$tag = "v$newVersion"
$asset = "$modId-$newVersion.zip"
$assetFound = $false
& gh release view $tag -R $Repo --json assets --jq '.assets[].name' 2>$null | ForEach-Object {
    if ($_.Trim() -eq $asset) { $assetFound = $true }
}
if (-not $assetFound) { throw "Release $tag exists, but '$asset' was not found." }

Write-Host ""
Write-Host "PUBLISHED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Version: $newVersion"
Write-Host "Repo:    https://github.com/$Repo"
Write-Host "Release: https://github.com/$Repo/releases/tag/$tag"
Write-Host "Asset:   $asset"
