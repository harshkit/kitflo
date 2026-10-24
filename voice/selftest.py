"""End-to-end check on this Mac: `python -I selftest.py [fixture.wav]`. Starts a real server on a spare port with a temp data dir."""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
PRO = "--pro" in sys.argv  # also run the Pro training end to end (about 20 min, ~9 GB; stop other model processes first)
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
FIXTURE = ARGS[0] if ARGS else "/Users/harshsharma/Music/deepak-original-reference.wav"
EN = "Hello there. Today is a good day to build something useful, and we have 3 apples."
TA = "வணக்கம், இன்று நாம் ஒன்றாக வேலை செய்யலாம்."
KEY, USER_KEY = "selftest-app-key", "kf_selftest"
rows = []


def check(name, ok, detail=""):
    rows.append((name, bool(ok), detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)
    return ok


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(port, data):
    env = {**os.environ, "KITFLO_APP_KEY": KEY, "KITFLO_PARENT_PID": str(os.getpid())}
    return subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "server.py"), "--port", str(port), "--data", data],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def footprint_sampler(peak):
    """Track the largest memory footprint (GPU included, via `footprint --json`) of the Pro training child process."""
    def run():
        while not peak["stop"]:
            for pid in subprocess.run(["pgrep", "-f", "pro.py train --out"], capture_output=True, text=True).stdout.split()[:1]:
                subprocess.run(["footprint", "--json", "/tmp/kitflo-fp.json", pid], capture_output=True)
                try:
                    peak["gb"] = max(peak["gb"], json.load(open("/tmp/kitflo-fp.json"))["total footprint"] / 2 ** 30)
                except (OSError, ValueError, KeyError):
                    pass
            time.sleep(2)
    threading.Thread(target=run, daemon=True).start()


def pro_section(call, vid, data, base):
    import numpy as np
    import soundfile as sf
    import server

    def wait(jid, timeout, every=3):
        t, seen = time.time(), []
        while time.time() - t < timeout:
            st, j = call("GET", f"/jobs/{jid}")
            if j.get("detail"):
                seen.append(j["detail"])
            if j["state"] != "running":
                return j, seen
            time.sleep(every)
        return {"state": "running", "error": "timed out"}, seen

    server.unload_whisper()  # this process's Whisper (3 GB) must not sit next to the training
    folder = tempfile.mkdtemp(prefix="voice-selftest-pro-")
    shutil.copy(FIXTURE, os.path.join(folder, "deepak.wav"))
    t = np.arange(24000 * 20) / 24000  # 20 s of chords plus hiss: music-like, not speech
    mus = sum(np.sin(2 * np.pi * f * t) for f in (220, 277, 330, 440)) * 0.15 + np.random.default_rng(0).normal(0, 0.01, len(t))
    sf.write(os.path.join(folder, "music.wav"), mus.astype("float32"), 24000)
    st, other = call("POST", "/speak", {"voice_id": "", "language": "en", "preset": "fast", "seed": 5,
                                        "text": "Good morning everyone. This is somebody else speaking, a completely different voice, reading a few short sentences for the test."})
    if st == 200:
        shutil.copy(other["path"], os.path.join(folder, "someone-else.wav"))
    open(os.path.join(folder, "broken.mp3"), "wb").write(b"not audio at all" * 20)

    t0 = time.time()
    st, r = call("POST", "/pro/scan", {"voice_id": vid, "folder": folder})
    j, seen = wait(r["job_id"], 900) if st == 200 else ({"state": "failed", "error": str(r)}, [])
    res = j.get("result") or {}
    print("SCAN RESULT", json.dumps(res), flush=True)
    check("pro scan", j["state"] == "done" and res.get("kept_minutes", 0) > 0.3 and res.get("files_failed") == 1 and res.get("dropped_minutes", 0) > 0,
          f"{time.time() - t0:.0f}s kept={res.get('kept_minutes')} min dropped={res.get('dropped')} failed={res.get('files_failed')} thr={res.get('threshold')} {j.get('error', '')}")
    if j["state"] != "done":
        return

    peak = {"gb": 0.0, "stop": False}
    footprint_sampler(peak)
    t0 = time.time()
    st, r = call("POST", "/pro/train", {"voice_id": vid, "dataset_id": res["dataset_id"], "steps": 60})
    check("pro train starts", st == 200, str(r)[:100])
    st, h = call("GET", "/health", key=None)
    check("health says training", h.get("status") == "training", str(h.get("status")))
    st, e = call("POST", "/speak", {"voice_id": vid, "language": "en", "text": "Hello.", "preset": "fast"})
    check("speak while training -> 409", st == 409 and "training" in e.get("error", ""), str(e)[:100])
    j, seen = wait(r["job_id"], 3600, every=5)
    peak["stop"] = True
    ab = j.get("result") or {}
    steps_seen = [d for d in seen if d.get("step")]
    print("AB RESULT", json.dumps(ab.get("scores")), flush=True)
    check("pro train + A/B", j["state"] == "done" and ab.get("scores") and steps_seen, f"{time.time() - t0:.0f}s peak {peak['gb']:.1f} GB last detail {seen[-1] if seen else None} {j.get('error', '')}")
    if j["state"] != "done":
        return
    sc = ab["scores"]
    check("A/B scored base and pro", all(k in sc[t] for t in ("base", "pro") for k in ("match", "utmos", "cer")), json.dumps(sc))
    check("A/B wavs written", all(os.path.isfile(os.path.join(ab["ab_dir"], f"{s}-{k}.wav")) for s in "AB" for k in (1, 2, 3)) and [x["k"] for x in ab.get("pairs", [])] == [1, 2, 3] and all(x["pro"] in "AB" and x["text"] for x in ab["pairs"]))
    st, h = call("GET", "/health", key=None)
    check("engine ready again", h.get("status") == "ready", str(h))
    voice = call("GET", "/voices")[1]["voices"][0]
    check("voice.json has pro", bool(voice.get("pro")) and voice["pro"]["steps"] == 60, str(voice.get("pro"))[:120])
    for en in (True, False):
        st, vv = call("POST", f"/voices/{vid}/pro/enabled", {"enabled": en})
        t1 = time.time()
        st, sp = call("POST", "/speak", {"voice_id": vid, "language": "en", "text": "Speaking with the adapter " + ("on." if en else "off."), "preset": "fast", "seed": 9})
        check(f"speak with pro {'enabled' if en else 'disabled'}", st == 200 and sp.get("similarity") and os.path.isfile(sp["path"]), f"{time.time() - t1:.0f}s sim={sp.get('similarity')} {sp.get('error', '')}")
    # cancel: leaves the voice usable and reloads the speaking model
    st, r = call("POST", "/pro/train", {"voice_id": vid, "dataset_id": res["dataset_id"], "steps": 300})
    if st != 200:
        check("cancel training", False, str(r)[:100])
        return
    for _ in range(60):
        st, jj = call("GET", f"/jobs/{r['job_id']}")
        if (jj.get("detail") or {}).get("step", 0) >= 1:
            break
        time.sleep(3)
    call("POST", "/pro/cancel", {"job_id": r["job_id"]})
    j, _ = wait(r["job_id"], 300)
    for _ in range(60):
        st, h = call("GET", "/health", key=None)
        if h.get("status") == "ready":
            break
        time.sleep(3)
    st, sp = call("POST", "/speak", {"voice_id": vid, "language": "en", "text": "Still works.", "preset": "fast"})
    check("cancel training", j["state"] == "failed" and "cancel" in j.get("error", "").lower() and h.get("status") == "ready" and st == 200
          and bool(call("GET", "/voices")[1]["voices"][0].get("pro")), f"{j.get('error')} {h.get('status')} (existing adapter kept)")
    check("DELETE pro", call("DELETE", f"/voices/{vid}/pro")[0] == 200 and "pro" not in call("GET", "/voices")[1]["voices"][0]
          and not os.path.exists(os.path.join(data, "voices", vid, "pro", "adapter"))
          and not os.path.exists(os.path.join(data, "voices", vid, "pro", "datasets")))


def main():
    if not os.path.isfile(FIXTURE):
        sys.exit(f"Fixture not found: {FIXTURE}. Pass a 20+ s speech recording as the first argument.")
    data, port = tempfile.mkdtemp(prefix="voice-selftest-"), free_port()
    base = f"http://127.0.0.1:{port}"
    proc = start(port, data)

    def call(method, path, body=None, key=KEY, raw=False, headers=None):
        req = urllib.request.Request(base + path, method=method, data=body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None,
                                     headers={**({"Authorization": f"Bearer {key}"} if key else {}), **(headers or {})})
        try:
            r = urllib.request.urlopen(req, timeout=900)
        except urllib.error.HTTPError as e:
            r = e
        data_ = r.read()
        return r.status, (data_ if raw else json.loads(data_))

    try:
        t = time.time()
        while True:
            try:
                st, h = call("GET", "/health", key=None)
            except OSError:
                st, h = 0, {}
            if h.get("status") == "ready":
                break
            if h.get("status") == "error" or proc.poll() is not None or time.time() - t > 240:
                check("server ready", False, str(h))
                return
            time.sleep(1)
        check("server ready", True, f"{time.time() - t:.0f}s")
        with open(os.path.join(data, "voice-api.json"), "w") as f:
            json.dump({"enabled": True, "key": USER_KEY}, f)

        t = time.time()
        st, p = call("POST", "/voices/prepare", {"audio_path": FIXTURE})
        ok = st == 200 and 3 <= p["duration_s"] <= 10 and p["ref_text"] and p["language"] == "en" and len(p["waveform"]) == 200
        check("prepare", ok, f"{time.time() - t:.0f}s {p.get('duration_s')}s q={p.get('quality', {}).get('score')} {p.get('error', '')}")
        if not ok:
            return
        check("Host header outside 127.0.0.1/localhost -> 403", call("GET", "/voices", headers={"Host": "evil.example.com"})[0] == 403)
        check("save without consent -> 400", call("POST", "/voices/save", {"name": "x", "language": "en", "ref_path": p["ref_path"], "ref_text": p["ref_text"], "consent": False})[0] == 400)
        st, v = call("POST", "/voices/save", {"name": "Self", "language": "en", "ref_path": p["ref_path"], "ref_text": p["ref_text"], "consent": True})
        check("save", st == 200 and "en" in v["voice"]["languages"], str(v)[:80] if st != 200 else "")
        check("scratch prepare file removed after save", not os.path.exists(p["ref_path"]))
        vid = v["voice"]["id"]
        st, again = call("POST", "/voices/save", {"voice_id": vid, "name": "x", "language": "en", "ref_path": p["ref_path"], "ref_text": p["ref_text"], "consent": True})
        check("re-saving a used sample -> 'already saved'", st == 400 and "already saved" in again.get("error", ""))
        check("ref_path outside voice-tmp -> 400", call("POST", "/voices/save", {"voice_id": vid, "language": "en", "ref_path": FIXTURE, "ref_text": "x", "consent": True})[0] == 400)
        vs = call("GET", "/voices")[1]["voices"]
        ceil = vs[0]["languages"]["en"].get("ceiling") if vs else None
        check("voices list + ceiling stored", [x["id"] for x in vs] == [vid] and isinstance(ceil, float) and 0.3 < ceil <= 1, f"ceiling={ceil}")

        import server  # reuse its Whisper + CER; CPU so it doesn't compete with the server's MPS memory
        server.DEVICE = "cpu"
        server.CFG["data"] = data

        def speak(lang, text, preset):
            t = time.time()
            st, r = call("POST", "/speak", {"voice_id": vid, "language": lang, "text": text, "preset": preset, "speed": 1.0, "seed": 11})
            return r, time.time() - t, st

        def cer_of(r, lang, text):
            import soundfile as sf
            x, sr = sf.read(r["path"], dtype="float32")
            return server.cer(text, server.transcribe(x, sr, lang)[0])

        en, dt, st = speak("en", EN, "balanced")
        c = cer_of(en, "en", EN) if st == 200 else 1
        check("speak en balanced", st == 200 and c < 0.15, f"{dt:.0f}s CER={c:.3f} sim={en.get('similarity')} {en.get('error', '')}")
        ta, dt, st = speak("ta", TA, "balanced")
        c = cer_of(ta, "ta", TA) if st == 200 else 1
        check("speak ta balanced", st == 200 and c < 0.5, f"{dt:.0f}s CER={c:.3f} matched={ta.get('language_matched')} {ta.get('error', '')}")
        stu, dt, st = speak("en", EN, "studio")
        c = cer_of(stu, "en", EN) if st == 200 else 1
        check("speak en studio", st == 200 and c < 0.15 and stu.get("takes") == 4, f"{dt:.0f}s CER={c:.3f} sim={stu.get('similarity')} int={stu.get('intelligibility')} {stu.get('error', '')}")
        check("speak returns match in (0, 1]", all(0 < r.get("match", 0) <= 1 for r in (en, stu)), f"balanced={en.get('match')} studio={stu.get('match')}")
        check("studio similarity >= balanced - 0.02", st == 200 and stu["similarity"] >= en["similarity"] - 0.02, f"{stu.get('similarity')} vs {en.get('similarity')}")

        check("text over 5000 chars -> 400", call("POST", "/speak", {"voice_id": vid, "language": "en", "text": "a" * 5001})[0] == 400)
        check("bad speed type -> 400", call("POST", "/speak", {"voice_id": vid, "language": "en", "text": "Hi.", "speed": "fast"})[0] == 400)
        st, w = call("POST", f"/voices/{vid}/warm", {"language": "en"})
        check("warm", st == 200 and w.get("ok"), str(w)[:80])
        st, jb = call("POST", "/speak/jobs", {"voice_id": vid, "language": "en", "text": "First part here. Second part there.", "preset": "fast"})
        seen = []
        while st == 200:
            st2, j = call("GET", f"/jobs/{jb['job_id']}")
            seen.append(round(j["progress"], 2))
            if j["state"] != "running":
                break
            time.sleep(1)
        check("speak job", st == 200 and j["state"] == "done" and os.path.isfile(j["result"]["path"]), f"progress {seen[-4:]} {j.get('error', '')}")

        body = {"model": "tts-1", "input": "Short test.", "voice": "Self", "response_format": "wav", "quality": "fast"}
        check("/v1 speech without key -> 401", call("POST", "/v1/audio/speech", body, key=None)[0] == 401)
        st, wav = call("POST", "/v1/audio/speech", body, key=USER_KEY, raw=True)
        check("/v1 speech with user key -> wav", st == 200 and wav[:4] == b"RIFF", f"{len(wav)} bytes")
        check("/v1 speech mp3 -> 400", call("POST", "/v1/audio/speech", {**body, "response_format": "mp3"}, key=USER_KEY)[0] == 400)
        with open(os.path.join(data, "voice-api.json"), "w") as f:
            json.dump({"enabled": False, "key": USER_KEY}, f)
        check("/v1 disabled key -> 401", call("POST", "/v1/audio/speech", body, key=USER_KEY)[0] == 401)

        st, e = call("POST", "/enhance", {"audio_path": FIXTURE, "level": "studio"})
        check("enhance studio", st == 200 and os.path.isfile(e["path"]) and abs(e["after_lufs"] + 16) < 1, f"{e.get('before_lufs')} -> {e.get('after_lufs')} LUFS")
        st, wav = call("POST", "/v1/audio/enhance?level=clean", open(FIXTURE, "rb").read(), key=KEY, raw=True)
        check("/v1 enhance bytes", st == 200 and wav[:4] == b"RIFF")

        if PRO:
            pro_section(call, vid, data, base)

        # parent-death watchdog: kill a parent and the child server must exit by itself
        wd_port = free_port()
        launcher = subprocess.Popen([sys.executable, "-I", "-c",
                                     "import subprocess,sys,time;p=subprocess.Popen(sys.argv[1:]);print(p.pid,flush=True);time.sleep(120)",
                                     sys.executable, "-I", os.path.join(HERE, "server.py"), "--port", str(wd_port), "--data", tempfile.mkdtemp(prefix="voice-selftest-wd-")],
                                    env={**os.environ, "KITFLO_APP_KEY": KEY}, stdout=subprocess.PIPE)
        child = int(launcher.stdout.readline())
        for _ in range(60):  # the watchdog starts with main(); don't kill the parent before it exists
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{wd_port}/health", timeout=1)
                break
            except OSError:
                time.sleep(1)
        launcher.kill()
        for _ in range(12):
            time.sleep(1)
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
        else:
            os.kill(child, signal.SIGKILL)
            child = None
        check("server exits when parent dies", child is not None)

        # KITFLO_PARENT_PID pointing at a process that no longer exists
        done = subprocess.Popen(["true"])
        done.wait()
        gone = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "server.py"), "--port", str(free_port()), "--data", tempfile.mkdtemp(prefix="voice-selftest-wd-")],
                                env={**os.environ, "KITFLO_APP_KEY": KEY, "KITFLO_PARENT_PID": str(done.pid)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            gone.wait(timeout=20)
        except subprocess.TimeoutExpired:
            gone.kill()
        check("server exits when KITFLO_PARENT_PID is gone", gone.returncode == 0)
    finally:
        proc.terminate()
        shutil.rmtree(data, ignore_errors=True)


try:
    main()
except Exception as ex:
    check("selftest crashed", False, f"{type(ex).__name__}: {ex}")
print("\n" + "\n".join(f"{'PASS' if ok else 'FAIL'}  {n}" for n, ok, _ in rows))
sys.exit(0 if rows and all(ok for _, ok, _ in rows) else 1)
