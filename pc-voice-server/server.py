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

import asyncio
import base64
import csv
import datetime
import json

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, Response, StreamingResponse
from pydantic import BaseModel

# ---- eSpeak (English parts) can't read its data from a non-ASCII folder ----
# Nave's Windows user folder is Hebrew, so espeak-ng failed and killed the
# server on English words. Copy its data to an ASCII path and point to it.
def _fix_espeak_path():
    try:
        import shutil

        import espeakng_loader

        data = espeakng_loader.get_data_path()
        lib = espeakng_loader.get_library_path()
        if str(data).isascii() and str(lib).isascii():
            return
        root = os.path.join(os.environ.get("PUBLIC", r"C:\Users\Public"), "NaveGlassesVoice", "espeak")
        if not root.isascii():
            root = r"C:\NaveGlassesVoice\espeak"
        new_data = os.path.join(root, "espeak-ng-data")
        new_lib = os.path.join(root, os.path.basename(str(lib)))
        if not os.path.isdir(new_data):
            shutil.copytree(data, new_data)
        if not os.path.exists(new_lib):
            shutil.copy2(lib, new_lib)
        espeakng_loader.get_data_path = lambda: new_data
        espeakng_loader.get_library_path = lambda: new_lib
        os.environ["ESPEAK_DATA_PATH"] = new_data
        print(f"[espeak] using {root}")
    except Exception as e:
        print(f"[espeak] path fix skipped: {e}")


_fix_espeak_path()

# ---- GPU (RTX) when available: ~10x faster than CPU for this model ----
import onnxruntime as ort

try:
    ort.preload_dlls()  # loads CUDA/cuDNN from the nvidia-* pip wheels if present
except Exception:
    pass
_GPU = "CUDAExecutionProvider" in ort.get_available_providers()

import blue_onnx  # noqa: E402

_orig_load_onnx = blue_onnx.load_onnx


def _load_onnx(path, opts, providers):
    if _GPU:
        try:
            return ort.InferenceSession(path, sess_options=opts,
                                        providers=["CUDAExecutionProvider", "CPUExecutionProvider"])
        except Exception as e:  # missing CUDA DLLs etc. → CPU
            print(f"[gpu] falling back to CPU: {e}")
    return _orig_load_onnx(path, opts, providers)


blue_onnx.load_onnx = _load_onnx
from blue_onnx import BlueTTS  # noqa: E402

STEPS = int(os.environ.get("NAVE_TTS_STEPS", "5"))

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX_DIR = os.path.join(HERE, "onnx_models")
VOICES_DIR = os.path.join(HERE, "voices")
PORT = int(os.environ.get("NAVE_VOICE_PORT", "8790"))
# Where recordings, photos, inventory and ideas land. Override with NAVE_MEDIA_DIR.
MEDIA_DIR = os.environ.get(
    "NAVE_MEDIA_DIR", os.path.join(os.path.expanduser("~"), "Videos", "NaveGlasses"))
os.makedirs(MEDIA_DIR, exist_ok=True)

app = FastAPI(title="Nave Glasses Voice")
_lock = threading.Lock()
_engine: BlueTTS | None = None
_styles: dict = {}


def available_voices() -> list[str]:
    return sorted(f[:-5] for f in os.listdir(VOICES_DIR) if f.endswith(".json"))


def engine() -> BlueTTS:
    """One model in memory for all voices (loading it per voice was slow)."""
    global _engine
    if _engine is None:
        _engine = BlueTTS(onnx_dir=ONNX_DIR, style_json=os.path.join(VOICES_DIR, "noa.json"))
    return _engine


def style(voice: str):
    from blue_onnx import load_voice_style

    if voice not in available_voices():
        voice = "noa"
    if voice not in _styles:
        _styles[voice] = load_voice_style([os.path.join(VOICES_DIR, f"{voice}.json")])
    return _styles[voice]


def synth(text: str, lang: str, voice: str, speed: float = 1.0):
    from blue_onnx import limit_peak

    e = engine()
    audio, _ = e.tts(text, lang=lang, style=style(voice), total_step=STEPS, speed=speed, normalize_text=True)
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim == 2:
        audio = audio[0]
    return limit_peak(audio, 0.95), e.sample_rate


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
        samples, sr = synth(text, lang, req.voice, max(0.5, min(2.0, req.speed)))
    buf = io.BytesIO()
    sf.write(buf, np.asarray(samples, dtype=np.float32), sr, format="WAV", subtype="PCM_16")
    print(f"[tts] {len(req.text)} chars, voice={req.voice}, {time.time() - t0:.2f}s")
    return Response(content=buf.getvalue(), media_type="audio/wav")


# ---------------------------------------------------------------- media ----

def _today_dir(kind: str) -> str:
    d = os.path.join(MEDIA_DIR, kind, datetime.date.today().isoformat())
    os.makedirs(d, exist_ok=True)
    return d


def _safe_name(name: str, default_ext: str) -> str:
    base = os.path.basename(name or "")
    base = re.sub(r"[^\w.\-]+", "_", base) or f"clip{default_ext}"
    stamp = datetime.datetime.now().strftime("%H%M%S")
    root, ext = os.path.splitext(base)
    return f"{stamp}_{root}{ext or default_ext}"


@app.post("/upload")
async def upload(request: Request):
    """Raw body upload of a recorded clip/photo from the glasses."""
    name = _safe_name(request.headers.get("x-filename", ""), ".mp4")
    path = os.path.join(_today_dir("recordings"), name)
    size = 0
    with open(path, "wb") as f:
        async for chunk in request.stream():
            f.write(chunk)
            size += len(chunk)
    print(f"[upload] {path} ({size // 1024} KB)")
    return {"ok": True, "path": path}


class LogEntry(BaseModel):
    kind: str = "inventory"  # inventory | idea | note
    text: str
    image_b64: str | None = None


@app.post("/log")
def log_entry(entry: LogEntry):
    now = datetime.datetime.now()
    photo = ""
    if entry.image_b64:
        photo = os.path.join(_today_dir("photos"), now.strftime("%H%M%S") + f"_{entry.kind}.jpg")
        with open(photo, "wb") as f:
            f.write(base64.b64decode(entry.image_b64))
    if entry.kind == "inventory":
        path = os.path.join(MEDIA_DIR, "inventory.csv")
        new = not os.path.exists(path)
        with open(path, "a", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["date", "time", "item", "photo"])
            w.writerow([now.date().isoformat(), now.strftime("%H:%M"), entry.text, photo])
    else:
        path = os.path.join(MEDIA_DIR, "ideas.md" if entry.kind == "idea" else "notes.md")
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"- {now:%Y-%m-%d %H:%M} — {entry.text}" + (f" ([photo]({photo}))" if photo else "") + "\n")
    print(f"[log:{entry.kind}] {entry.text}")
    return {"ok": True, "file": path}


# -------------------------------------------------------- OBS camera ----

_latest_jpeg: bytes | None = None
_frame_event = asyncio.Event()


@app.websocket("/cam/push")
async def cam_push(ws: WebSocket):
    """The phone pushes JPEG frames from the glasses here."""
    global _latest_jpeg
    await ws.accept()
    print("[cam] glasses camera connected")
    try:
        while True:
            _latest_jpeg = await ws.receive_bytes()
            _frame_event.set()
            _frame_event.clear()
    except WebSocketDisconnect:
        print("[cam] glasses camera disconnected")


async def _mjpeg():
    boundary = b"--frame\r\n"
    while True:
        try:
            await asyncio.wait_for(_frame_event.wait(), timeout=2)
        except asyncio.TimeoutError:
            pass
        if _latest_jpeg:
            yield boundary + b"Content-Type: image/jpeg\r\n\r\n" + _latest_jpeg + b"\r\n"


@app.get("/cam.mjpg")
async def cam_mjpg():
    return StreamingResponse(_mjpeg(), media_type="multipart/x-mixed-replace; boundary=frame")


@app.get("/cam", response_class=HTMLResponse)
def cam_page():
    """Add this URL in OBS as a Browser Source (1080x1920 or 720x1280)."""
    return """<html><body style="margin:0;background:#000;overflow:hidden">
<img src="/cam.mjpg" style="width:100vw;height:100vh;object-fit:cover"></body></html>"""


# --------------------------------------------------- TikTok live chat ----

class _TikTok:
    def __init__(self):
        self.events: list[dict] = []
        self.next_id = 1
        self.username = ""
        self.status = "stopped"
        self.thread: threading.Thread | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.client = None
        self.lock = threading.Lock()

    def push(self, kind: str, user: str, text: str):
        with self.lock:
            self.events.append({"id": self.next_id, "type": kind, "user": user, "text": text})
            self.next_id += 1
            self.events = self.events[-300:]

    def start(self, username: str):
        self.stop()
        from TikTokLive import TikTokLiveClient
        from TikTokLive.events import CommentEvent, ConnectEvent, DisconnectEvent, FollowEvent, GiftEvent, LiveEndEvent

        self.username = username.lstrip("@")
        client = TikTokLiveClient(unique_id="@" + self.username)
        self.client = client

        def name(ev):
            u = getattr(ev, "user", None)
            return (getattr(u, "nickname", None) or getattr(u, "unique_id", None) or "מישהו") if u else "מישהו"

        @client.on(ConnectEvent)
        async def _c(_):
            self.status = "live"
            print(f"[tiktok] connected to @{self.username}")

        @client.on(DisconnectEvent)
        async def _d(_):
            self.status = "stopped"
            print("[tiktok] disconnected")

        @client.on(LiveEndEvent)
        async def _e(_):
            self.status = "ended"

        @client.on(CommentEvent)
        async def _m(ev):
            text = getattr(ev, "content", "") or getattr(ev, "comment", "")
            if text:
                self.push("comment", name(ev), text)

        @client.on(FollowEvent)
        async def _f(ev):
            self.push("follow", name(ev), "")

        @client.on(GiftEvent)
        async def _g(ev):
            gift = getattr(getattr(ev, "gift", None), "name", "") or "מתנה"
            streaking = getattr(ev, "streaking", False)
            if not streaking:
                self.push("gift", name(ev), gift)

        def runner():
            self.loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.loop)
            self.status = "connecting"
            try:
                self.loop.run_until_complete(client.connect())
            except Exception as e:  # not live, user not found, sign server limits…
                self.status = f"error: {e}"
                print(f"[tiktok] {e}")
            finally:
                if self.status in ("live", "connecting"):
                    self.status = "stopped"

        self.thread = threading.Thread(target=runner, daemon=True)
        self.thread.start()

    def stop(self):
        if self.client and self.loop and self.loop.is_running():
            asyncio.run_coroutine_threadsafe(self.client.disconnect(), self.loop)
        self.client = None
        self.status = "stopped"


_tiktok = _TikTok()


class TikTokStart(BaseModel):
    username: str


@app.post("/tiktok/start")
def tiktok_start(req: TikTokStart):
    if not req.username.strip():
        raise HTTPException(400, "username required")
    _tiktok.start(req.username.strip())
    return {"ok": True}


@app.post("/tiktok/stop")
def tiktok_stop():
    _tiktok.stop()
    return {"ok": True}


@app.get("/tiktok/events")
def tiktok_events(after: int = 0):
    with _tiktok.lock:
        items = [e for e in _tiktok.events if e["id"] > after]
    return {"status": _tiktok.status, "username": _tiktok.username, "events": items}


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
    print("Device:", "GPU (CUDA)" if _GPU else "CPU — run gpu.bat once for a much faster voice")
    with _lock:
        for v in available_voices():  # warm up every voice + fetch Hebrew G2P weights
            t0 = time.time()
            synth("שלום, אני מוכן.", "he", v)
            print(f"  voice {v} ready ({time.time() - t0:.1f}s)")
    print("\n================ Nave Glasses Voice is running ================")
    print("Type ONE of these addresses into the app (Settings -> Voice -> PC):")
    for ip in local_ips():
        tag = "  (Tailscale - works from anywhere)" if ip.startswith("100.") else "  (home Wi-Fi)"
        print(f"   http://{ip}:{PORT}{tag}")
    print("Voices:", ", ".join(available_voices()))
    print(f"Media folder: {MEDIA_DIR}")
    print(f"OBS camera (Browser Source): http://localhost:{PORT}/cam")
    print("Leave this window open. Close it to stop the voice server.")
    print("===============================================================\n")
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
