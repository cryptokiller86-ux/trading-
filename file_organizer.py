#!/usr/bin/env python3
"""
Organisateur de bureau - classe automatiquement fichiers et dossiers par type.
Usage: python file_organizer.py [chemin] [--dry-run] [--undo]
"""

import os
import shutil
import json
import argparse
from pathlib import Path
from datetime import datetime

# Classification des extensions par catégorie
CATEGORIES = {
    "Images": [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".svg", ".webp", ".ico", ".tiff", ".raw", ".heic"],
    "Videos": [".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpeg", ".3gp"],
    "Musique": [".mp3", ".wav", ".flac", ".aac", ".ogg", ".wma", ".m4a", ".opus"],
    "Documents": [".pdf", ".doc", ".docx", ".odt", ".txt", ".rtf", ".tex", ".pages"],
    "Tableurs": [".xls", ".xlsx", ".ods", ".csv"],
    "Présentations": [".ppt", ".pptx", ".odp", ".key"],
    "Archives": [".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz", ".iso"],
    "Code": [".py", ".js", ".ts", ".html", ".css", ".java", ".c", ".cpp", ".h", ".cs",
             ".php", ".rb", ".go", ".rs", ".sh", ".bat", ".ps1", ".json", ".xml", ".yaml", ".yml"],
    "Exécutables": [".exe", ".msi", ".dmg", ".deb", ".rpm", ".AppImage"],
    "Polices": [".ttf", ".otf", ".woff", ".woff2"],
    "Trading_MQL5": [".mq5", ".mq4", ".ex5", ".ex4", ".set"],
}

LOG_FILE = ".organizer_history.json"


def get_category(ext: str) -> str:
    ext = ext.lower()
    for category, extensions in CATEGORIES.items():
        if ext in extensions:
            return category
    return "Divers"


def load_history(directory: Path) -> list:
    log_path = directory / LOG_FILE
    if log_path.exists():
        with open(log_path) as f:
            return json.load(f)
    return []


def save_history(directory: Path, moves: list):
    log_path = directory / LOG_FILE
    history = load_history(directory)
    history.extend(moves)
    with open(log_path, "w") as f:
        json.dump(history, f, indent=2, ensure_ascii=False)


def organize(directory: Path, dry_run: bool = False) -> dict:
    moves = []
    stats = {}
    skipped = []

    items = [p for p in directory.iterdir() if p.name not in (LOG_FILE, ".DS_Store", "desktop.ini")]

    for item in sorted(items):
        if item.is_dir():
            # Ne pas déplacer les dossiers déjà créés par l'organisateur
            if item.name in CATEGORIES or item.name == "Divers":
                continue
            category = "Dossiers"
        else:
            category = get_category(item.suffix)

        dest_dir = directory / category
        dest_path = dest_dir / item.name

        # Gérer les conflits de noms
        if dest_path.exists():
            stem = item.stem
            suffix = item.suffix
            counter = 1
            while dest_path.exists():
                new_name = f"{stem}_{counter}{suffix}" if suffix else f"{stem}_{counter}"
                dest_path = dest_dir / new_name
                counter += 1

        if dry_run:
            print(f"  [APERÇU] {item.name:40s} → {category}/{dest_path.name}")
        else:
            dest_dir.mkdir(exist_ok=True)
            shutil.move(str(item), str(dest_path))
            moves.append({
                "original": str(item),
                "moved_to": str(dest_path),
                "timestamp": datetime.now().isoformat()
            })

        stats[category] = stats.get(category, 0) + 1

    if not dry_run and moves:
        save_history(directory, moves)

    return stats, moves, skipped


def undo(directory: Path, steps: int = 1):
    history = load_history(directory)
    if not history:
        print("Aucun historique trouvé. Impossible d'annuler.")
        return

    # Prendre les N dernières opérations
    to_undo = history[-steps:]
    remaining = history[:-steps]

    restored = 0
    for move in reversed(to_undo):
        src = Path(move["moved_to"])
        dst = Path(move["original"])
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
            print(f"  Restauré: {src.name} → {dst.parent.name}/")
            restored += 1
        else:
            print(f"  Introuvable: {src} (peut-être déjà déplacé)")

    # Nettoyer les dossiers vides créés par l'organisateur
    for category in list(CATEGORIES.keys()) + ["Divers", "Dossiers"]:
        cat_dir = directory / category
        if cat_dir.exists() and not any(cat_dir.iterdir()):
            cat_dir.rmdir()

    # Mettre à jour l'historique
    log_path = directory / LOG_FILE
    with open(log_path, "w") as f:
        json.dump(remaining, f, indent=2, ensure_ascii=False)
    if not remaining:
        log_path.unlink()

    print(f"\n{restored} fichier(s) restauré(s).")


def print_stats(stats: dict, dry_run: bool):
    total = sum(stats.values())
    mode = "APERÇU" if dry_run else "RÉSULTAT"
    print(f"\n{'='*50}")
    print(f"  {mode} — {total} élément(s) traité(s)")
    print(f"{'='*50}")
    for category, count in sorted(stats.items(), key=lambda x: -x[1]):
        bar = "█" * min(count, 30)
        print(f"  {category:<20s} {bar} {count}")
    print(f"{'='*50}\n")


def main():
    parser = argparse.ArgumentParser(description="Organisateur de fichiers pour bureau")
    parser.add_argument("chemin", nargs="?", default=str(Path.home() / "Desktop"),
                        help="Dossier à organiser (défaut: Bureau)")
    parser.add_argument("--dry-run", "-n", action="store_true",
                        help="Aperçu sans déplacer les fichiers")
    parser.add_argument("--undo", "-u", action="store_true",
                        help="Annuler la dernière organisation")
    parser.add_argument("--steps", type=int, default=None,
                        help="Nombre de fichiers à annuler avec --undo")
    args = parser.parse_args()

    directory = Path(args.chemin).expanduser().resolve()

    if not directory.exists():
        print(f"Erreur: Le dossier '{directory}' n'existe pas.")
        return 1

    print(f"\nDossier cible: {directory}")

    if args.undo:
        history = load_history(directory)
        steps = args.steps if args.steps else len(history)
        print(f"Annulation de {steps} déplacement(s)...\n")
        undo(directory, steps)
        return 0

    if args.dry_run:
        print("Mode APERÇU — aucun fichier ne sera déplacé.\n")

    stats, moves, _ = organize(directory, dry_run=args.dry_run)

    if not stats:
        print("\nAucun fichier à organiser (le dossier est déjà propre).")
    else:
        print_stats(stats, args.dry_run)
        if not args.dry_run:
            print(f"Historique sauvegardé dans: {directory / LOG_FILE}")
            print("Pour annuler: python file_organizer.py --undo\n")

    return 0


if __name__ == "__main__":
    exit(main())
