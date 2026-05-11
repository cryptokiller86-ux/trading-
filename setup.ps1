# ============================================================
#  YassoBot - Setup automatique
#  Lance ce script UNE SEULE FOIS en tant qu'Administrateur
# ============================================================

$DEST = "$env:USERPROFILE\Desktop\YassoBot"
$REPO = "https://github.com/cryptokiller86-ux/trading-"
$BRANCH = "claude/telegram-trading-bot-umi2o"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   YassoBot - Installation automatique  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Python ────────────────────────────────────────────────
Write-Host "[1/5] Verification de Python..." -ForegroundColor Yellow
$pythonOk = $null -ne (Get-Command python -ErrorAction SilentlyContinue)
if (-not $pythonOk) {
    Write-Host "  Installation de Python 3.11..." -ForegroundColor Gray
    winget install --id Python.Python.3.11 --silent --accept-package-agreements --accept-source-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
} else {
    Write-Host "  Python deja installe." -ForegroundColor Green
}

# ── 2. Git ────────────────────────────────────────────────────
Write-Host "[2/5] Verification de Git..." -ForegroundColor Yellow
$gitOk = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if (-not $gitOk) {
    Write-Host "  Installation de Git..." -ForegroundColor Gray
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
} else {
    Write-Host "  Git deja installe." -ForegroundColor Green
}

# ── 3. Clone du depot ─────────────────────────────────────────
Write-Host "[3/5] Telechargement du bot sur le Bureau..." -ForegroundColor Yellow
if (Test-Path $DEST) {
    Write-Host "  Dossier existant, mise a jour..." -ForegroundColor Gray
    Set-Location $DEST
    git pull origin $BRANCH
} else {
    git clone --branch $BRANCH $REPO $DEST
    Set-Location $DEST
}
Write-Host "  Dossier cree : $DEST" -ForegroundColor Green

# ── 4. Dependances Python ─────────────────────────────────────
Write-Host "[4/5] Installation des dependances Python..." -ForegroundColor Yellow
python -m pip install --upgrade pip --quiet
python -m pip install -r requirements.txt --quiet
Write-Host "  Dependances installees." -ForegroundColor Green

# ── 5. Fichier .env ───────────────────────────────────────────
Write-Host "[5/5] Creation du fichier de configuration..." -ForegroundColor Yellow
if (-not (Test-Path "$DEST\.env")) {
    Copy-Item "$DEST\.env.example" "$DEST\.env"
    Write-Host "  Fichier .env cree." -ForegroundColor Green
} else {
    Write-Host "  Fichier .env deja present (non ecrase)." -ForegroundColor Green
}

# ── Raccourci Bureau ──────────────────────────────────────────
$batPath = "$DEST\LANCER.bat"
$shortcutPath = "$env:USERPROFILE\Desktop\Lancer YassoBot.lnk"
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($shortcutPath)
$Shortcut.TargetPath = $batPath
$Shortcut.WorkingDirectory = $DEST
$Shortcut.IconLocation = "C:\Windows\System32\cmd.exe"
$Shortcut.Description = "Lancer le copieur de signaux YassoBot"
$Shortcut.Save()
Write-Host "  Raccourci cree sur le Bureau." -ForegroundColor Green

# ── Fin ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Installation terminee !              " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "PROCHAINE ETAPE :" -ForegroundColor White
Write-Host "  Ouvre le fichier LISEZ-MOI.txt dans le dossier YassoBot" -ForegroundColor Yellow
Write-Host "  sur ton Bureau pour savoir quoi remplir dans .env" -ForegroundColor Yellow
Write-Host ""
Write-Host "Appuie sur une touche pour ouvrir le dossier..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
explorer $DEST
