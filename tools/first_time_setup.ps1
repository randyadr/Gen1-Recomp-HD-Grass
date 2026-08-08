$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Owner = "randyadr"
$RepoName = "Gen1-Recomp-HD-Grass"
$Repo = "$Owner/$RepoName"
$RemoteUrl = "https://github.com/$Repo.git"
$ApiUrl = "https://api.github.com/repos/$Repo/releases?per_page=100"
$ManifestPath = Join-Path $RepoRoot "manifest.json"

Set-Location $RepoRoot

function Ensure-WingetTool {
    param([string]$Command, [string]$PackageId, [string]$DisplayName)
    if (Get-Command $Command -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$DisplayName is required but was not found, and winget is unavailable. Install $DisplayName, then run FIRST_TIME_SETUP.bat again."
    }
    Write-Host "$DisplayName was not found. Installing it with winget..." -ForegroundColor Yellow
    & winget install --id $PackageId -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install $DisplayName." }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "$DisplayName installed, but this shell cannot see it yet. Close this window and run FIRST_TIME_SETUP.bat again."
    }
}

function Git {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
    & git @Args
    if ($LASTEXITCODE -ne 0) { throw "git $($Args -join ' ') failed." }
}

Ensure-WingetTool "git" "Git.Git" "Git for Windows"
Ensure-WingetTool "gh" "GitHub.cli" "GitHub CLI"

if (-not (Test-Path $ManifestPath)) { throw "manifest.json is missing from $RepoRoot" }
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ([string]$manifest.github -ne $Repo) {
    throw "manifest.json github field is '$($manifest.github)' but this package expects '$Repo'."
}
$version = [string]$manifest.version
$modId = [string]$manifest.id
$tag = "v$version"
$assetName = "$modId-$version.zip"
$assetPath = Join-Path $RepoRoot ("dist\" + $assetName)

Write-Host "Target repository: $Repo" -ForegroundColor Cyan
Write-Host "Current version:   $version" -ForegroundColor Cyan

# Authenticate in the browser if needed.
& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub login is required. A browser window will open." -ForegroundColor Yellow
    & gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw "GitHub login failed." }
}

$login = (& gh api user --jq .login 2>$null | Select-Object -First 1).Trim()
if ($login -ne $Owner) {
    Write-Host "GitHub CLI is currently using '$login', not '$Owner'." -ForegroundColor Yellow
    & gh auth switch --hostname github.com --user $Owner
    if ($LASTEXITCODE -ne 0) {
        throw "Please log into GitHub CLI as '$Owner', then run FIRST_TIME_SETUP.bat again."
    }
    $login = (& gh api user --jq .login 2>$null | Select-Object -First 1).Trim()
    if ($login -ne $Owner) { throw "Active GitHub account is '$login', expected '$Owner'." }
}

# Prepare a normal git repository if this came from a ZIP.
if (-not (Test-Path (Join-Path $RepoRoot ".git"))) {
    Git init
    Git branch -M main
}
if ([string]::IsNullOrWhiteSpace((& git config user.name 2>$null))) {
    Git config user.name $Owner
}
if ([string]::IsNullOrWhiteSpace((& git config user.email 2>$null))) {
    Git config user.email "$Owner@users.noreply.github.com"
}

# Commit the complete repo before creating the remote.
Git add -A
& git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Git commit -m "Release $tag"
} elseif (-not (& git rev-parse --verify HEAD 2>$null)) {
    throw "Nothing was committed and the repository has no HEAD commit."
}

# Check authenticated GitHub first. A private repo is visible here even though
# Gen1Recomp's unauthenticated updater would receive 404.
$repoJson = $null
try {
    $repoJson = (& gh repo view $Repo --json nameWithOwner,isPrivate,defaultBranchRef 2>$null | ConvertFrom-Json)
} catch { $repoJson = $null }

if ($null -eq $repoJson) {
    Write-Host "Repository does not exist yet. Creating PUBLIC repository..." -ForegroundColor Green
    # Remove a stale origin that may have been left by an older broken package.
    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) { Git remote remove origin }
    & gh repo create $Repo --public --source $RepoRoot --remote origin --push --description "Gen1Recomp custom 3D grass OBJ replacement for Dramatic Shape and Dramaless Shape"
    if ($LASTEXITCODE -ne 0) { throw "GitHub could not create $Repo." }
} else {
    if ($repoJson.isPrivate -eq $true) {
        Write-Host "The repository exists, but it is PRIVATE." -ForegroundColor Red
        Write-Host "Gen1Recomp checks GitHub without your private login, so a private repo returns HTTP 404." -ForegroundColor Red
        $answer = Read-Host "Make $Repo public now? Type YES to continue"
        if ($answer -ne "YES") { throw "Repository must be public for Gen1Recomp's GitHub release updater." }
        & gh repo edit $Repo --visibility public --accept-visibility-change-consequences
        if ($LASTEXITCODE -ne 0) { throw "Could not change repository visibility to public." }
    }

    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) { Git remote set-url origin $RemoteUrl } else { Git remote add origin $RemoteUrl }

    # If the remote already has main, rebase onto it to avoid overwriting history.
    & git fetch origin main *> $null
    if ($LASTEXITCODE -eq 0) {
        & git pull --rebase --autostash origin main
        if ($LASTEXITCODE -ne 0) { throw "Could not rebase onto the existing remote main branch." }
    }
    Git push -u origin main
}

# Make sure the current installable asset exists. The repo ZIP already ships it.
if (-not (Test-Path $assetPath)) {
    if (Get-Command python -ErrorAction SilentlyContinue) {
        & python (Join-Path $RepoRoot "tools\build_release.py") --output $assetPath
        if ($LASTEXITCODE -ne 0) { throw "Could not build $assetName" }
    } elseif (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3 (Join-Path $RepoRoot "tools\build_release.py") --output $assetPath
        if ($LASTEXITCODE -ne 0) { throw "Could not build $assetName" }
    } else {
        throw "Release asset '$assetName' is missing and Python is not installed to rebuild it."
    }
}

# Create the release immediately instead of waiting for Actions.
& gh release view $tag -R $Repo *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Release $tag already exists. Refreshing its ZIP asset..." -ForegroundColor Yellow
    & gh release upload $tag $assetPath --clobber -R $Repo
    if ($LASTEXITCODE -ne 0) { throw "Could not upload release asset." }
} else {
    Write-Host "Creating GitHub Release $tag..." -ForegroundColor Green
    & gh release create $tag $assetPath -R $Repo --target main --title $tag --notes "Gen1Recomp Grass OBJ Replacer $version"
    if ($LASTEXITCODE -ne 0) { throw "Could not create GitHub Release $tag." }
}

# Verify the exact endpoint Gen1Recomp calls, WITHOUT authentication.
Write-Host "Verifying Gen1Recomp updater endpoint..." -ForegroundColor Cyan
$headers = @{ "User-Agent" = "gen1recomp-grass-setup"; "Accept" = "application/vnd.github+json" }
try {
    $releases = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -Method Get
} catch {
    throw "The public updater URL still failed: $ApiUrl`n$($_.Exception.Message)"
}
if ($null -eq $releases) { throw "GitHub returned no release data from $ApiUrl" }

$found = $false
foreach ($rel in @($releases)) {
    foreach ($asset in @($rel.assets)) {
        if ($asset.name -eq $assetName) { $found = $true; break }
    }
    if ($found) { break }
}
if (-not $found) {
    throw "The repository is public, but release asset '$assetName' was not found by the updater endpoint."
}

Write-Host "" 
Write-Host "SUCCESS" -ForegroundColor Green
Write-Host "Public repo:     https://github.com/$Repo"
Write-Host "Release:         https://github.com/$Repo/releases/tag/$tag"
Write-Host "Updater API:     $ApiUrl"
Write-Host "Release asset:   $assetName"
Write-Host "" 
Write-Host "Gen1Recomp's 404 is now fixed at the source. Restart Gen1Recomp and open F10 again." -ForegroundColor Green
