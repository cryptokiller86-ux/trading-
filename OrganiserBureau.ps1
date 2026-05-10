# ============================================================
#  OrganiserBureau.ps1  —  Assistant IA Personnel
#  Organise automatiquement le Bureau Windows
#  Usage : clic-droit > Exécuter avec PowerShell
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

# ---------- COULEURS CONSOLE ----------
function Write-Ok($msg)   { Write-Host "[OK] $msg"  -ForegroundColor Green  }
function Write-Info($msg) { Write-Host "[>>] $msg"  -ForegroundColor Cyan   }
function Write-Warn($msg) { Write-Host "[!!] $msg"  -ForegroundColor Yellow }

Clear-Host
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "   ASSISTANT IA — ORGANISATION DU BUREAU   " -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

# ---------- CHEMIN DU BUREAU ----------
$Bureau = [Environment]::GetFolderPath("Desktop")
Write-Info "Bureau détecté : $Bureau"
Write-Host ""

# ---------- CONFIRMATION ----------
$confirm = Read-Host "Lancer l'organisation du bureau ? (O/N)"
if ($confirm -notmatch "^[Oo]$") {
    Write-Warn "Opération annulée."
    exit
}

# ============================================================
#  STRUCTURE DE DOSSIERS CIBLES
# ============================================================
$dossiers = @(
    "Trading",
    "Trading\EAs",
    "Trading\Charts",
    "Trading\Rapports",
    "Documents Importants",
    "Screenshots",
    "Téléchargements triés",
    "Archives",
    "IA",
    "Projets",
    "Images",
    "Vidéos",
    "Musique",
    "Installateurs",
    "Divers"
)

Write-Info "Création de la structure de dossiers..."
foreach ($d in $dossiers) {
    $chemin = Join-Path $Bureau $d
    if (-not (Test-Path $chemin)) {
        New-Item -ItemType Directory -Path $chemin -Force | Out-Null
        Write-Ok "Créé : $d"
    }
}
Write-Host ""

# ============================================================
#  RÈGLES DE CLASSEMENT
#  Format : @{ Extensions = @(...); Destination = "Dossier" }
# ============================================================
$regles = @(
    # --- Trading / MQL5 ---
    @{ Extensions = @(".mq4",".mq5",".ex4",".ex5",".mql"); Destination = "Trading\EAs" },

    # --- Documents ---
    @{ Extensions = @(".pdf",".doc",".docx",".odt",".rtf",".txt",".md"); Destination = "Documents Importants" },

    # --- Tableurs ---
    @{ Extensions = @(".xls",".xlsx",".ods",".csv"); Destination = "Documents Importants" },

    # --- Présentations ---
    @{ Extensions = @(".ppt",".pptx",".odp"); Destination = "Documents Importants" },

    # --- Images ---
    @{ Extensions = @(".jpg",".jpeg",".png",".gif",".bmp",".webp",".svg",".ico"); Destination = "Images" },

    # --- Screenshots (noms typiques) ---
    # (géré ci-dessous par pattern de nom)

    # --- Vidéos ---
    @{ Extensions = @(".mp4",".mkv",".avi",".mov",".wmv",".flv",".webm"); Destination = "Vidéos" },

    # --- Musique ---
    @{ Extensions = @(".mp3",".wav",".flac",".ogg",".aac",".wma"); Destination = "Musique" },

    # --- Installateurs ---
    @{ Extensions = @(".exe",".msi",".msix",".appx"); Destination = "Installateurs" },

    # --- Archives ---
    @{ Extensions = @(".zip",".rar",".7z",".tar",".gz",".bz2"); Destination = "Archives" },

    # --- IA / Scripts ---
    @{ Extensions = @(".py",".ipynb",".json",".yaml",".yml",".toml"); Destination = "IA" },

    # --- Scripts système ---
    @{ Extensions = @(".ps1",".bat",".cmd",".sh"); Destination = "Projets" }
)

# ============================================================
#  CLASSEMENT DES FICHIERS
# ============================================================
Write-Info "Classement des fichiers en cours..."
$fichiers = Get-ChildItem -Path $Bureau -File

$deplacés   = 0
$ignorés    = 0

foreach ($fichier in $fichiers) {

    # Ne pas déplacer ce script lui-même
    if ($fichier.Name -eq "OrganiserBureau.ps1") { continue }

    $ext         = $fichier.Extension.ToLower()
    $nom         = $fichier.Name.ToLower()
    $destination = $null

    # --- Détection Screenshots par nom ---
    if ($nom -match "^(screenshot|capture|écran|screen|grab|snip)" -or
        $nom -match "^\d{4}-\d{2}-\d{2}.*\.(png|jpg|jpeg)$") {
        $destination = "Screenshots"
    }

    # --- Détection fichiers Trading par nom ---
    elseif ($nom -match "(trading|forex|xauusd|btc|gold|scalp|ea_|robot)" ) {
        $destination = "Trading"
    }

    # --- Application des règles d'extension ---
    else {
        foreach ($regle in $regles) {
            if ($regle.Extensions -contains $ext) {
                $destination = $regle.Destination
                break
            }
        }
    }

    # --- Fichier non reconnu → Divers ---
    if (-not $destination) {
        $destination = "Divers"
    }

    # --- Déplacement ---
    $cible = Join-Path $Bureau $destination
    $fichierCible = Join-Path $cible $fichier.Name

    # Éviter les conflits de noms
    if (Test-Path $fichierCible) {
        $horodatage   = Get-Date -Format "yyyyMMdd_HHmmss"
        $nouveauNom   = "$($fichier.BaseName)_$horodatage$($fichier.Extension)"
        $fichierCible = Join-Path $cible $nouveauNom
    }

    Move-Item -Path $fichier.FullName -Destination $fichierCible -Force
    Write-Ok "$($fichier.Name) → $destination"
    $deplacés++
}

# ============================================================
#  NETTOYAGE : RACCOURCIS CASSÉS
# ============================================================
Write-Host ""
Write-Info "Vérification des raccourcis cassés..."
$raccourcis = Get-ChildItem -Path $Bureau -Filter "*.lnk"
$raccourcisCassés = 0

foreach ($lnk in $raccourcis) {
    $shell  = New-Object -ComObject WScript.Shell
    $sc     = $shell.CreateShortcut($lnk.FullName)
    $cibleLnk = $sc.TargetPath

    if ($cibleLnk -and -not (Test-Path $cibleLnk)) {
        Write-Warn "Raccourci cassé détecté : $($lnk.Name)"
        $suppr = Read-Host "   Supprimer ce raccourci cassé ? (O/N)"
        if ($suppr -match "^[Oo]$") {
            Remove-Item $lnk.FullName -Force
            Write-Ok "Supprimé : $($lnk.Name)"
            $raccourcisCassés++
        }
    }
}

# ============================================================
#  RAPPORT FINAL
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "   RAPPORT D'ORGANISATION" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Ok "Fichiers déplacés       : $deplacés"
Write-Ok "Raccourcis cassés       : $raccourcisCassés supprimé(s)"
Write-Host ""

# Afficher le contenu final du bureau
Write-Info "Contenu actuel du bureau :"
Get-ChildItem -Path $Bureau | ForEach-Object {
    if ($_.PSIsContainer) {
        Write-Host "  [DOSSIER] $($_.Name)" -ForegroundColor Blue
    } else {
        Write-Host "  [FICHIER] $($_.Name)" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "Bureau organisé avec succès !" -ForegroundColor Green
Write-Host ""
Read-Host "Appuie sur ENTRÉE pour fermer"
