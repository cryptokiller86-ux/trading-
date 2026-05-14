@echo off
title Assistant IA — Organisateur Bureau
color 0D

echo.
echo  ============================================
echo    ASSISTANT IA — LANCEMENT ORGANISATEUR
echo  ============================================
echo.

:: Cherche le script dans le meme dossier que ce .bat
set "SCRIPT=%~dp0OrganiserBureau.ps1"

if not exist "%SCRIPT%" (
    echo  [ERREUR] OrganiserBureau.ps1 introuvable !
    echo  Place ce fichier .bat dans le meme dossier que OrganiserBureau.ps1
    echo.
    pause
    exit /b 1
)

echo  Script trouve : %SCRIPT%
echo  Lancement en cours...
echo.

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [ERREUR] Le script a rencontre une erreur ^(code : %ERRORLEVEL%^)
    echo  Verifiez que PowerShell est bien installe sur votre systeme.
)

echo.
echo  Termine.
pause
