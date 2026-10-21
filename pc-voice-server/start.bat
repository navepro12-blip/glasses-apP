@echo off
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
title Nave Glasses Voice
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
cd /d "%USERPROFILE%\NaveGlassesVoice\BlueTTS"
:loop
uv run --no-sync python server.py
echo.
echo The voice server stopped - restarting in 3 seconds (close this window to stop it)...
timeout /t 3 >nul
goto loop
