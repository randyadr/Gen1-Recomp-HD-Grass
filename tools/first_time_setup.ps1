param([switch]$ToolsOnly)
$ErrorActionPreference = "Stop"

function Ensure-WingetTool {
    param([string]$Command, [string]$PackageId, [string]$DisplayName)
    if (Get-Command $Command -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$DisplayName is required but was not found, and winget is unavailable. Install $DisplayName manually."
    }
    Write-Host "$DisplayName was not found. Installing with winget..." -ForegroundColor Yellow
    & winget install --id $PackageId -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install $DisplayName." }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

Ensure-WingetTool "git" "Git.Git" "Git for Windows"
Ensure-WingetTool "gh" "GitHub.cli" "GitHub CLI"

if ($ToolsOnly) { exit 0 }

& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "A browser window will open for GitHub login." -ForegroundColor Yellow
    & gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw "GitHub login failed." }
}

Write-Host "Setup complete. Run PUBLISH_UPDATE.bat to attach/push this folder." -ForegroundColor Green
