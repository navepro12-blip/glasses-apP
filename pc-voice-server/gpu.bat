@echo off
chcp 65001 >nul
set PYTHONUTF8=1
title Nave Glasses Voice - GPU setup
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
cd /d "%USERPROFILE%\NaveGlassesVoice\BlueTTS"
echo Switching the voice model to the NVIDIA GPU (one time, ~1 GB download)...
uv pip uninstall onnxruntime
uv pip install "onnxruntime-gpu[cuda,cudnn]>=1.24" TikTokLive
if errorlevel 1 (
  echo GPU install failed - restoring the CPU version.
  uv pip install onnxruntime
)
copy /y "%~dp0server.py" server.py >nul 2>nul
echo Done. Starting the voice server...
call "%USERPROFILE%\NaveGlassesVoice\start.bat"
