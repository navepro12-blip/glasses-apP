# Nave Glasses Voice (PC)

Free, local Hebrew voice for the glasses app, using [BlueTTS](https://github.com/maxmelichov/Light-BlueTTS) (MIT).

1. Download this repo as ZIP (green **Code** button → **Download ZIP**) and extract it.
2. Open `pc-voice-server` and **right-click `setup.bat` → Run as administrator** (one time).
3. When it finishes it prints an address like `http://192.168.1.20:8765` — type it in the app:
   Settings → Voice provider → **PC (free)**.
4. Next times: double-click `start.bat` in `%USERPROFILE%\NaveGlassesVoice`.

Away from home: install Tailscale on the PC and the iPhone, and use the `100.x.x.x` address.
