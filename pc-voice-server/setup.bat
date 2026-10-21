@echo off
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
title Nave Glasses Voice - setup
echo === Nave Glasses Voice: one-time setup ===
set "DEST=%USERPROFILE%\NaveGlassesVoice"
if not exist "%DEST%" mkdir "%DEST%"
cd /d "%DEST%"

where uv >nul 2>nul
if errorlevel 1 (
  echo Installing uv ^(Python manager^)...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
  set "PATH=%USERPROFILE%\.local\bin;%PATH%"
)

echo Downloading BlueTTS ^(free Hebrew voice, MIT license^)...
powershell -NoProfile -Command "Invoke-WebRequest https://github.com/maxmelichov/Light-BlueTTS/archive/refs/heads/main.zip -OutFile bluetts.zip; Expand-Archive -Force bluetts.zip .; Remove-Item bluetts.zip"
if exist BlueTTS rmdir /s /q BlueTTS
for /d %%D in (Light-BlueTTS-* BlueTTS-*) do ren "%%D" BlueTTS
cd BlueTTS

echo Installing Python packages ^(a few minutes^)...
uv sync || goto :fail
uv pip install fastapi "uvicorn[standard]" || goto :fail

echo Downloading the voice model...
uv run hf download notmax123/BlueTTS2.5-onnx --repo-type model --local-dir ./onnx_models || goto :fail

copy /y "%~dp0server.py" server.py >nul
copy /y "%~dp0start.bat" "%DEST%\start.bat" >nul

echo Opening the Windows firewall for port 8790 ^(home network only^)...
netsh advfirewall firewall add rule name="Nave Glasses Voice" dir=in action=allow protocol=TCP localport=8790 profile=private >nul 2>nul

echo.
echo === Setup done. Starting the voice server... ===
call "%DEST%\start.bat"
goto :eof

:fail
echo.
echo *** Setup failed. Take a screenshot of this window and send it to Claude. ***
pause
