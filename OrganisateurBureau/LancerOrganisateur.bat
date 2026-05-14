@echo off
title Assistant IA - Organisateur Bureau
color 0D

echo.
echo  ============================================
echo    ASSISTANT IA - LANCEMENT ORGANISATEUR
echo  ============================================
echo.
echo  Lancement en cours...
echo.

PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& {
$ErrorActionPreference = 'SilentlyContinue'

function Write-Ok($msg)   { Write-Host '[OK] ' -NoNewline -ForegroundColor Green;  Write-Host $msg }
function Write-Info($msg) { Write-Host '[>>] ' -NoNewline -ForegroundColor Cyan;   Write-Host $msg }
function Write-Warn($msg) { Write-Host '[!!] ' -NoNewline -ForegroundColor Yellow; Write-Host $msg }

Clear-Host
Write-Host '============================================' -ForegroundColor Magenta
Write-Host '   ASSISTANT IA - ORGANISATION DU BUREAU   ' -ForegroundColor Magenta
Write-Host '============================================' -ForegroundColor Magenta
Write-Host ''

$Bureau = [Environment]::GetFolderPath('Desktop')
Write-Info \"Bureau detecte : $Bureau\"
Write-Host ''

$confirm = Read-Host 'Lancer l organisation du bureau ? (O/N)'
if ($confirm -notmatch '^[Oo]$') { Write-Warn 'Operation annulee.'; Read-Host 'Appuie sur ENTREE pour fermer'; exit }

$dossiers = @('Trading','Trading\EAs','Trading\Charts','Trading\Rapports','Documents Importants','Screenshots','Telechargements tries','Archives','IA','Projets','Images','Videos','Musique','Installateurs','Divers')

Write-Info 'Creation de la structure de dossiers...'
foreach ($d in $dossiers) {
    $chemin = Join-Path $Bureau $d
    if (-not (Test-Path $chemin)) {
        New-Item -ItemType Directory -Path $chemin -Force | Out-Null
        Write-Ok \"Cree : $d\"
    }
}
Write-Host ''

$regles = @(
    @{ Extensions = @('.mq4','.mq5','.ex4','.ex5','.mql'); Destination = 'Trading\EAs' },
    @{ Extensions = @('.pdf','.doc','.docx','.odt','.rtf','.txt','.md'); Destination = 'Documents Importants' },
    @{ Extensions = @('.xls','.xlsx','.ods','.csv'); Destination = 'Documents Importants' },
    @{ Extensions = @('.jpg','.jpeg','.png','.gif','.bmp','.webp','.svg','.ico'); Destination = 'Images' },
    @{ Extensions = @('.mp4','.mkv','.avi','.mov','.wmv','.flv','.webm'); Destination = 'Videos' },
    @{ Extensions = @('.mp3','.wav','.flac','.ogg','.aac','.wma'); Destination = 'Musique' },
    @{ Extensions = @('.exe','.msi','.msix','.appx'); Destination = 'Installateurs' },
    @{ Extensions = @('.zip','.rar','.7z','.tar','.gz','.bz2'); Destination = 'Archives' },
    @{ Extensions = @('.py','.ipynb','.json','.yaml','.yml','.toml'); Destination = 'IA' },
    @{ Extensions = @('.ps1','.bat','.cmd','.sh'); Destination = 'Projets' }
)

Write-Info 'Classement des fichiers en cours...'
$fichiers = Get-ChildItem -Path $Bureau -File
$deplaces = 0

foreach ($fichier in $fichiers) {
    $ext = $fichier.Extension.ToLower()
    $nom = $fichier.Name.ToLower()
    $destination = $null

    if ($nom -match '^(screenshot|capture|screen|grab|snip)' -or $nom -match '^\d{4}-\d{2}-\d{2}.*\.(png|jpg|jpeg)$') {
        $destination = 'Screenshots'
    } elseif ($nom -match '(trading|forex|xauusd|btc|gold|scalp|ea_|robot)') {
        $destination = 'Trading'
    } else {
        foreach ($regle in $regles) {
            if ($regle.Extensions -contains $ext) { $destination = $regle.Destination; break }
        }
    }

    if (-not $destination) { $destination = 'Divers' }

    $cible = Join-Path $Bureau $destination
    $fichierCible = Join-Path $cible $fichier.Name

    if (Test-Path $fichierCible) {
        $h = Get-Date -Format 'yyyyMMdd_HHmmss'
        $fichierCible = Join-Path $cible \"$($fichier.BaseName)_$h$($fichier.Extension)\"
    }

    Move-Item -Path $fichier.FullName -Destination $fichierCible -Force
    Write-Ok \"$($fichier.Name) >> $destination\"
    $deplaces++
}

Write-Host ''
Write-Host '============================================' -ForegroundColor Magenta
Write-Host '   RAPPORT FINAL' -ForegroundColor Magenta
Write-Host '============================================' -ForegroundColor Magenta
Write-Ok \"Fichiers deplaces : $deplaces\"
Write-Host ''
Write-Host 'Bureau organise avec succes !' -ForegroundColor Green
Write-Host ''
Read-Host 'Appuie sur ENTREE pour fermer'
}"

echo.
pause
