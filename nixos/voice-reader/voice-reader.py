"""Voice reader: reads the selected text aloud (Kokoro, local, PT/EN).

  voice-reader daemon    -> loads the model and waits for requests on the socket
  voice-reader read      -> sends the current selection; if already speaking, stops
  voice-reader translate -> translates the selection (Argos Translate, local) and reads the translation
"""
import json
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
SOCK = os.path.join(RUNTIME, "voice-reader.sock")
STATE_FILE = os.path.join(RUNTIME, "voice-reader.json")
VOICES = {"pt": ("p", "pf_dora"), "en": ("a", "af_heart")}
SPEED = float(os.environ.get("VOICE_READER_SPEED", "1.0"))
# Translation target language ("pt" or "en"); text already in it goes to the other one.
TRANSLATE_TO = os.environ.get("VOICE_READER_TRANSLATE_TO", "pt")
# langdetect code -> Argos code (Brazilian Portuguese is "pb").
ARGOS = {"pt": "pb", "zh-cn": "zh", "zh-tw": "zt", "no": "nb"}

# Generate and play sentence by sentence: Kokoro's default ("\n+") turns a whole
# paragraph into a single chunk, which must be synthesized before playing.
SENTENCES = r"(?<=[.!?…;:])\s+|\n+"
# Estimated delay between writing to pw-play and the sound coming out (caption sync).
LATENCY = float(os.environ.get("VOICE_READER_LATENCY", "0.1"))
PUNCT_ONLY = re.compile(r"^[^\w]+$")


def words(result, dur: float) -> list:
    """[[word, start_ms, end_ms], ...] relative to the start of the sentence audio."""
    toks = result.tokens or []
    if toks and all(t.start_ts is not None for t in toks if not PUNCT_ONLY.match(t.text)):
        # English: Kokoro gives the real timing of each token; punctuation sticks to the word.
        out: list = []
        for t in toks:
            if out and PUNCT_ONLY.match(t.text):
                out[-1][0] += t.text
                if t.end_ts is not None:
                    out[-1][2] = round(t.end_ts * 1000)
            elif t.start_ts is not None:
                out.append([t.text, round(t.start_ts * 1000), round((t.end_ts or t.start_ts) * 1000)])
        return out
    # Portuguese: no per-word timing; spread the duration by each word's length,
    # with an extra pause after comma/period.
    ws = result.graphemes.split()
    if not ws:
        return []
    weights = [len(re.sub(r"\W", "", w)) + 1 + (3 if re.search(r"[,;:.!?…]$", w) else 0) for w in ws]
    start, usable = 0.2, max(dur - 0.4, 0.1)
    out, t = [], start
    for w, p in zip(ws, weights):
        d = usable * p / sum(weights)
        out.append([w, round(t * 1000), round((t + d) * 1000)])
        t += d
    return out


def selection() -> str:
    for args in (["wl-paste", "-p", "-n"], ["wl-paste", "-n"]):
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return ""


def send(mode: str) -> None:
    request = {"mode": mode, "text": selection()}
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(SOCK)
        s.sendall(json.dumps(request).encode())


def notify(msg: str) -> None:
    print(msg, flush=True)
    try:
        subprocess.run(["notify-send", "-a", "Voice Reader", "Voice Reader", msg])
    except FileNotFoundError:
        pass


def translator(source: str, target: str):
    """Translation function source -> target; downloads missing models
    (once, ~100 MB per pair). Without a direct pair, pivots through English."""
    # MiniSBD: lightweight sentence splitter; the default (Stanza) takes ~4 s to load.
    os.environ.setdefault("ARGOS_CHUNK_TYPE", "MINISBD")
    import argostranslate.package as pk
    import argostranslate.translate as tr

    src, dst = ARGOS.get(source, source), ARGOS.get(target, target)

    def installed():
        try:
            return tr.get_translation_from_codes(src, dst)
        except AttributeError:  # language not installed
            return None

    if (t := installed()) is None:
        pk.update_package_index()
        avail = {(p.from_code, p.to_code): p for p in pk.get_available_packages()}
        pairs = [(src, dst)] if (src, dst) in avail else [(src, "en"), ("en", dst)]
        if any(pair not in avail for pair in pairs):
            raise LookupError(f"don't know how to translate from '{source}' to '{target}'")
        have = {(p.from_code, p.to_code) for p in pk.get_installed_packages()}
        for pair in pairs:
            if pair not in have:
                notify(f"Downloading translator {pair[0]} → {pair[1]} (first time only)…")
                pk.install_from_path(avail[pair].download())
        if (t := installed()) is None:
            raise LookupError(f"translation '{source}' → '{target}' unavailable")
    return t.translate


def daemon() -> None:
    from kokoro import KPipeline
    from langdetect import DetectorFactory, detect

    DetectorFactory.seed = 0
    pipes = {lang: KPipeline(lang_code=code, repo_id="hexgrad/Kokoro-82M")
             for lang, (code, _) in VOICES.items()}
    state = {"player": None, "gen": 0}
    lock = threading.Lock()
    write_lock = threading.Lock()

    def publish(status: str, lang: str = "", total: int = 0,
                timeline: list | None = None, source: str = "") -> None:
        # Read by the DMS plugin (VoiceReader/): bar and caption.
        # source != "" when translating (language of the selected text).
        with write_lock:
            with open(STATE_FILE + ".tmp", "w") as f:
                json.dump({"state": status, "lang": lang, "source": source,
                           "total": total, "sentences": timeline or []}, f)
            os.replace(STATE_FILE + ".tmp", STATE_FILE)

    def stop() -> None:
        state["gen"] += 1
        p = state["player"]
        if p and p.poll() is None:
            p.kill()
        state["player"] = None
        publish("idle")

    def speak(text: str, mode: str, gen: int) -> None:
        sentences = [s.strip() for s in re.split(SENTENCES, text) if s and s.strip()]
        total = max(1, len(sentences))
        try:
            detected = detect(text)
        except Exception:
            detected = "pt"
        if mode == "translate":
            source = detected
            lang = TRANSLATE_TO if source != TRANSLATE_TO else (
                "en" if TRANSLATE_TO == "pt" else "pt")
        else:
            source, lang = "", "pt" if detected == "pt" else "en"
        publish("loading", lang, total, source=source)
        print(f"{mode} [{source or lang} -> {lang}] {len(text)} characters, {total} sentences",
              flush=True)
        player = subprocess.Popen(
            ["pw-play", "--raw", "--rate", "24000", "--channels", "1", "--format", "f32", "-"],
            stdin=subprocess.PIPE)
        with lock:
            if gen != state["gen"]:
                player.kill()
                return
            state["player"] = player
        # Generate in one thread and play in another: writing to pw-play blocks when
        # the pipe fills, so generating in the same loop would leave gaps between sentences.
        q: queue.Queue = queue.Queue()

        def play() -> None:
            # Timeline in epoch ms: the caption finds the current word by the
            # clock. A sentence starts when the previous one finishes playing.
            timeline: list = []
            prev_end = 0.0
            try:
                while (item := q.get()) is not None:
                    audio, spoken = item
                    start = max(time.time() + LATENCY, prev_end)
                    prev_end = start + len(audio) / 4 / 24000
                    timeline.append({"start": round(start * 1000),
                                     "end": round(prev_end * 1000), "words": spoken})
                    if gen == state["gen"]:
                        # Kokoro still subdivides very long sentences.
                        publish("speaking", lang, max(total, len(timeline)), timeline, source)
                    player.stdin.write(audio)
                    player.stdin.flush()
                player.stdin.close()
                player.wait()
            except (BrokenPipeError, ValueError):
                pass
            with lock:
                if gen == state["gen"]:
                    state["player"] = None
                    publish("idle")

        def chunks():
            if not source:
                yield text
                return
            # Translate sentence by sentence: the first plays while the rest translate.
            translate = translator(source, lang)
            for s in sentences:
                yield translate(s)

        threading.Thread(target=play, daemon=True).start()
        try:
            for chunk in chunks():
                if gen != state["gen"]:
                    break
                for r in pipes[lang](chunk, voice=VOICES[lang][1], speed=SPEED,
                                     split_pattern=SENTENCES):
                    if gen != state["gen"]:
                        break
                    if r.audio is not None:
                        q.put((r.audio.numpy().astype("float32").tobytes(),
                               words(r, len(r.audio) / 24000)))
        except Exception as e:  # translation: language without model, no internet on first download
            if gen == state["gen"]:
                notify(f"Couldn't translate: {e}")
        finally:
            q.put(None)

    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(SOCK)
    srv.listen()
    publish("idle")
    print("voice-reader ready", flush=True)
    while True:
        conn, _ = srv.accept()
        with conn:
            data = b""
            while chunk := conn.recv(65536):
                data += chunk
        try:
            request = json.loads(data.decode(errors="ignore"))
            mode, text = request["mode"], request["text"].strip()
        except (ValueError, KeyError, AttributeError):
            continue
        with lock:
            speaking = state["player"] is not None and state["player"].poll() is None
            stop()
            gen = state["gen"]
        if speaking or not text:
            continue  # second keypress = stop
        threading.Thread(target=speak, args=(text, mode, gen), daemon=True).start()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "read"
    if mode == "daemon":
        daemon()
    elif mode in ("read", "translate"):
        send(mode)
    else:
        sys.exit(__doc__)
