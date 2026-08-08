$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Owner = "randyadr"
$RepoName = "gen1recomp-grass-obj-replacer"
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

if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "Git/GitHub CLI setup is incomplete. Running first-time setup..." -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FirstSetup
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub login expired/missing. Opening login..." -ForegroundColor Yellow
    & gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw "GitHub login failed." }
}

& gh repo view $Repo *> $null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $RepoRoot ".git"))) {
    Write-Host "Repository is not initialized yet. Running first-time setup..." -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FirstSetup
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& git remote get-url origin *> $null
if ($LASTEXITCODE -eq 0) { Git remote set-url origin $RemoteUrl } else { Git remote add origin $RemoteUrl }

# Bring down any web edits first.
& git fetch origin main *> $null
if ($LASTEXITCODE -eq 0) {
    & git pull --rebase --autostash origin main
    if ($LASTEXITCODE -ne 0) { throw "Could not update from origin/main." }
}

$statusBefore = (& git status --porcelain --untracked-files=all)
if ([string]::IsNullOrWhiteSpace(($statusBefore -join "`n"))) {
    Write-Host "There are no changed files to publish." -ForegroundColor Yellow
    Write-Host "If you only copied identical files over the folder, Git correctly sees no new update."
    Write-Host "Edit/replace a file with different contents, then run this again."
    exit 0
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ([string]$manifest.github -ne $Repo) { throw "manifest github field must be '$Repo'." }
$oldVersion = [string]$manifest.version
if ($oldVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "Version '$oldVersion' is not x.y.z." }
$newVersion = "{0}.{1}.{2}" -f $Matches[1], $Matches[2], ([int]$Matches[3] + 1)
$manifest.version = $newVersion
$json = $manifest | ConvertTo-Json -Depth 32
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ManifestPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Version: $oldVersion -> $newVersion" -ForegroundColor Green
Git add -A
Git commit -m "Release v$newVersion"
Git push -u origin main

# Wait for the push-triggered release workflow. This makes the BAT truly
# end-to-end instead of claiming success before the release exists.
Start-Sleep -Seconds 3
$runId = $null
for ($i = 0; $i -lt 20; $i++) {
    $runId = (& gh run list -R $Repo --workflow release.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null | Select-Object -First 1).Trim()
    if ($runId) { break }
    Start-Sleep -Seconds 2
}
if (-not $runId) { throw "Push succeeded, but no GitHub Actions release run appeared." }

Write-Host "Waiting for GitHub Actions release run $runId..." -ForegroundColor Cyan
& gh run watch $runId -R $Repo --exit-status
if ($LASTEXITCODE -ne 0) { throw "GitHub Actions release workflow failed." }

$tag = "v$newVersion"
& gh release view $tag -R $Repo *> $null
if ($LASTEXITCODE -ne 0) { throw "Workflow finished, but release $tag was not found." }

Write-Host "" 
Write-Host "PUBLISHED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Version: $newVersion"
Write-Host "Release: https://github.com/$Repo/releases/tag/$tag"
Write-Host "Gen1Recomp updater can now see this release."
