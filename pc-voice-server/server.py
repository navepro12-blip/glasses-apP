"""
Nave Glasses — free local Hebrew voice server (BlueTTS, MIT, runs on this PC).

The phone app POSTs text to /tts and gets back a WAV. Runs on the home Wi-Fi
(or over Tailscale from anywhere). Start it with start.bat.
"""
import builtins
import io
import os

# Windows with a Hebrew locale opens text files as cp1255 by default, which
# breaks loading the model's JSON files. Force UTF-8 for text-mode opens.
_builtin_open = builtins.open


def _utf8_open(file, mode="r", buffering=-1, encoding=None, *args, **kwargs):
    if "b" not in mode and encoding is None:
        encoding = "utf-8"
    return _builtin_open(file, mode, buffering, encoding, *args, **kwargs)


builtins.open = _utf8_open
import re
import socket
import threading
import time

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from blue_onnx import BlueTTS

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX_DIR = os.path.join(HERE, "onnx_models")
VOICES_DIR = os.path.join(HERE, "voices")
PORT = int(os.environ.get("NAVE_VOICE_PORT", "8790"))

app = FastAPI(title="Nave Glasses Voice")
_lock = threading.Lock()
_engines: dict[str, BlueTTS] = {}


def available_voices() -> list[str]:
    return sorted(f[:-5] for f in os.listdir(VOICES_DIR) if f.endswith(".json"))


def engine(voice: str) -> BlueTTS:
    if voice not in available_voices():
        voice = "noa"
    if voice not in _engines:
        _engines[voice] = BlueTTS(onnx_dir=ONNX_DIR, style_json=os.path.join(VOICES_DIR, f"{voice}.json"))
    return _engines[voice]


HEB = re.compile(r"[֐-׿]")
LATIN_RUN = re.compile(r"[A-Za-z][A-Za-z0-9'’\-\.\s]*[A-Za-z0-9]|[A-Za-z]")


def prepare(text: str) -> tuple[str, str]:
    """Hebrew text with English words → wrap the English in <en>…</en>."""
    text = text.strip()
    if not HEB.search(text):
        return text, "en"
    return LATIN_RUN.sub(lambda m: f"<en>{m.group(0).strip()}</en>", text), "he"


class TTSRequest(BaseModel):
    text: str
    voice: str = "noa"
    speed: float = 1.0


@app.get("/health")
def health():
    return {"ok": True, "voices": available_voices()}


@app.post("/tts")
def tts(req: TTSRequest):
    if not req.text.strip():
        raise HTTPException(400, "empty text")
    text, lang = prepare(req.text[:2000])
    t0 = time.time()
    with _lock:
        samples, sr = engine(req.voice).synthesize(text, lang=lang, speed=max(0.5, min(2.0, req.speed)))
    buf = io.BytesIO()
    sf.write(buf, np.asarray(samples, dtype=np.float32), sr, format="WAV", subtype="PCM_16")
    print(f"[tts] {len(req.text)} chars, voice={req.voice}, {time.time() - t0:.2f}s")
    return Response(content=buf.getvalue(), media_type="audio/wav")


def local_ips() -> list[str]:
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


if __name__ == "__main__":
    print("Loading the Hebrew voice model (first run downloads ~300 MB)...")
    with _lock:
        engine("noa").synthesize("שלום", lang="he")  # warm up + fetch Hebrew G2P weights
    print("\n================ Nave Glasses Voice is running ================")
    print("Type ONE of these addresses into the app (Settings -> Voice -> PC):")
    for ip in local_ips():
        tag = "  (Tailscale - works from anywhere)" if ip.startswith("100.") else "  (home Wi-Fi)"
        print(f"   http://{ip}:{PORT}{tag}")
    print("Voices:", ", ".join(available_voices()))
    print("Leave this window open. Close it to stop the voice server.")
    print("===============================================================\n")
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
