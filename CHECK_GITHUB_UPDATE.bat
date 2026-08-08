@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$u='https://api.github.com/repos/randyadr/Gen1-Recomp-HD-Grass/releases?per_page=100'; try {$r=Invoke-WebRequest -UseBasicParsing -Headers @{'User-Agent'='gen1recomp-check'} -Uri $u; Write-Host ('HTTP ' + [int]$r.StatusCode) -ForegroundColor Green; Write-Host $u; Write-Host 'The updater endpoint is reachable.' -ForegroundColor Green} catch {Write-Host $_.Exception.Message -ForegroundColor Red; exit 1}"
pause
