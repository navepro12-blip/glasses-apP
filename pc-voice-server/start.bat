@echo off
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
title Nave Glasses Voice
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
cd /d "%USERPROFILE%\NaveGlassesVoice\BlueTTS"
uv run --no-sync python server.py
echo.
echo The voice server stopped. Take a screenshot if there is an error.
pause
