@echo off
chcp 65001 >nul
title Nave Glasses Voice
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
cd /d "%USERPROFILE%\NaveGlassesVoice\BlueTTS"
uv run python server.py
echo.
echo The voice server stopped. Take a screenshot if there is an error.
pause
