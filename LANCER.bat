@echo off
title YassoBot - Copieur de signaux Telegram -> MT5
color 0A

echo.
echo  ==========================================
echo    YassoBot - Copieur de signaux actif
echo    Groupe : TheYassoGroup
echo    Broker : PUPrime MT5
echo  ==========================================
echo.

cd /d "%~dp0"

REM Verifie que .env existe
if not exist ".env" (
    echo  ERREUR : fichier .env manquant !
    echo  Lis le fichier LISEZ-MOI.txt pour savoir quoi faire.
    pause
    exit /b 1
)

REM Lance le bot
python main.py

echo.
echo  Le bot s'est arrete.
pause
