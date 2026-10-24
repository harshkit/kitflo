"""Pro training: fine-tune a LoRA adapter for one voice, then speak with it. Contract: PRO.md.

Three parts:
- scan: find the speaker's clean speech in a folder (runs inside the server, as a job)
- train: a child process (`python -I pro.py train ...`) so MPS memory goes back to the OS when it ends
- adapters: PEFT adapters loaded on top of the shared OmniVoice, never merged, at most 2 at a time

Server-side functions take `S`, the server module, instead of importing it (server.py runs as __main__).
"""
import contextlib
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timezone

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)  # python -I drops the script dir

import enhance  # noqa: E402

SR = 24000
BATCH_TOKENS = int(os.environ.get("KITFLO_PRO_BATCH_TOKENS", "2048"))  # memory knob: activations scale with this
MEDIA = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".mp4", ".mov", ".m4v", ".mkv", ".webm"}
BLOCK_S = 600  # long files are processed in 10-minute blocks so a 2-hour podcast doesn't need 2 GB of RAM
SAME_SPEAKER = 0.55
MAX_REMOVED = 0.35  # share of a clip's energy DeepFilterNet may remove (more means music, effects or heavy noise)
MIN_SNR = 15.0
ENOUGH_MIN = 30.0
FIXED_SENTENCES = [  # for A/B in English: new sentences the speaker never recorded
    "Hello, this is my voice reading a new sentence that I never actually recorded.",
    "Kitflo turns your words into clear speech, right here on your own Mac.",
    "The quick brown fox jumps over the lazy dog near the old river bank.",
]
REASONS = ("other_speaker", "music_or_noise", "clipping", "no_speech")


class Cancelled(Exception):
    pass


def pro_dir(S, vid, *p):
    return os.path.join(S.vdir(vid), "pro", *p)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


# ---------------------------------------------------------------- scan

def list_media(folder):
    out = []
    for root, _, files in os.walk(folder):
        out += [os.path.join(root, f) for f in files if os.path.splitext(f)[1].lower() in MEDIA and not f.startswith(".")]
    return sorted(out)


def audio_blocks(S, path):
    """Yield (offset_s, mono float32 at 24 kHz) in 10-minute blocks. afconvert handles mp4/mov/aac that libsndfile cannot."""
    tmp = None
    try:
        try:
            f = sf.SoundFile(path)
        except Exception:
            tmp = S.data_dir("voice-tmp", f"scan-{uuid.uuid4().hex[:8]}.wav")
            subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", path, tmp], check=True, capture_output=True)
            f = sf.SoundFile(tmp)
        with f:
            n, t = int(BLOCK_S * f.samplerate), 0.0
            while True:
                x = f.read(n, dtype="float32", always_2d=True)
                if not len(x):
                    return
                yield t, enhance.resample(x.mean(axis=1), f.samplerate, SR)
                t += len(x) / f.samplerate
    finally:
        if tmp and os.path.exists(tmp):
            os.remove(tmp)


def group_clips(segs):
    """Whisper segments -> (start, end, text) clips of 3-15 s, cut on segment boundaries. Returns (clips, leftovers)."""
    clips, short, cur = [], [], None
    for s, e, t in segs:
        if not t.strip():
            continue
        if cur and s - cur[1] <= 1.0 and e - cur[0] <= 15:
            cur = [cur[0], e, cur[2] + t]
            continue
        if cur:
            (clips if cur[1] - cur[0] >= 3 else short).append(tuple(cur))
        cur = [s, e, t] if e - s <= 15 else None
        if cur is None:
            short.append((s, e, t))  # a single segment longer than 15 s: not cut mid-sentence
    if cur:
        (clips if cur[1] - cur[0] >= 3 else short).append(tuple(cur))
    return clips, short


def frame_db(x, sr=SR):
    h = int(sr * 0.02)
    n = len(x) // h
    return 10 * np.log10(np.mean(x[: n * h].reshape(n, h) ** 2, axis=1) + 1e-10) if n else np.zeros(0)


def judge(S, raw, den, nrm, text, ref_embs, thr):
    """Return None to keep the clip, else the reason it is dropped."""
    dur = len(raw) / SR
    db = frame_db(den)
    voiced = float((db > max(np.percentile(db, 95) - 30, -60)).mean()) if len(db) else 0.0
    cps = len(re.sub(r"\W+", "", text)) / dur
    if len(text.strip()) < 3 or voiced < 0.5 or not 2 <= cps <= 40:  # Whisper's own no_speech score isn't exposed in long-form mode
        return "no_speech"
    if float((np.abs(raw) >= 0.99).mean()) > 0.001:
        return "clipping"
    rdb = frame_db(raw)
    if float(np.percentile(rdb, 90) - np.percentile(rdb, 10)) < MIN_SNR:
        return "music_or_noise"
    resid = raw[: len(den)] - den[: len(raw)]
    removed = float(np.sum(resid ** 2) / (np.sum(raw ** 2) + 1e-12))
    if removed > MAX_REMOVED:
        return "music_or_noise"
    if removed > 0.15:  # a tonal residual (low spectral flatness) is music, a flat one is noise DeepFilterNet handled
        from scipy.signal import welch
        p = welch(resid, SR, nperseg=1024)[1] + 1e-20
        if float(np.exp(np.mean(np.log(p))) / np.mean(p)) < 0.03:
            return "music_or_noise"
    emb = S.ecapa_embed(nrm, SR)
    if S.mean_cos(emb, ref_embs) < thr:
        return "other_speaker"
    return None


def scan(S, j, cancel, vid, folder):
    ds = uuid.uuid4().hex[:8]
    try:
        result = _scan(S, j, cancel, vid, folder, ds)
    except BaseException:
        shutil.rmtree(pro_dir(S, vid, "datasets", ds), ignore_errors=True)  # cancelled or failed: leave nothing behind
        raise
    for old in os.listdir(pro_dir(S, vid, "datasets")):  # only the newest dataset is kept
        if old != ds:
            shutil.rmtree(pro_dir(S, vid, "datasets", old), ignore_errors=True)
    return result


def _scan(S, j, cancel, vid, folder, ds):
    v = S.load_voice(vid)
    files = list_media(folder)
    if not files:
        raise S.bad("That folder has no audio or video files (wav, mp3, m4a, aac, flac, mp4, mov, m4v, mkv, webm). Pick the folder with the recordings.")
    refs = [S.ecapa_embed(*S.read_audio(p)[:2]) for p in sorted(os.path.join(S.vdir(vid), f) for f in os.listdir(S.vdir(vid)) if f.startswith("ref-") and f.endswith(".wav"))]
    if not refs:
        raise S.bad("That voice has no reference sample yet. Save a voice first, then scan.")
    ceilings = [l.get("ceiling") or S.CEILING_DEFAULT for l in v["languages"].values()]
    thr = round(max(0.45, min(SAME_SPEAKER, 0.7 * float(np.mean(ceilings)))), 3)  # calibrated with the voice's real-speech ceiling, never below 0.45
    lang_hint = next(iter(v["languages"]), None)
    dsdir = pro_dir(S, vid, "datasets", ds)
    os.makedirs(os.path.join(dsdir, "clips"), exist_ok=True)
    rows, dropped, kept_s, failed, rejected, n_clip = [], {k: 0.0 for k in REASONS + ("unusable_length",)}, 0.0, 0, [], 0
    langs = {}
    print(f"pro scan: {len(files)} files, same-speaker threshold {thr} (ceiling {np.mean(ceilings):.2f})", file=sys.stderr, flush=True)
    for fi, path in enumerate(files):
        j["detail"] = {"file": os.path.basename(path), "files_done": fi, "files_total": len(files), "kept_minutes": round(kept_s / 60, 2)}
        j["progress"], j["message"] = fi / len(files) * 0.98, f"Reading {os.path.basename(path)}"
        try:
            for t0, x in audio_blocks(S, path):
                if cancel.is_set():
                    raise Cancelled()
                if len(x) < 3 * SR:
                    continue
                den = enhance.denoise(x, SR)
                nrm = enhance.normalize(den, SR)
                _, segs, lang = S.transcribe(nrm, SR, lang_hint)
                S.unload_whisper()  # ~3 GB on a 16 GB Mac; reloads in 5-10 s
                clips, short = group_clips(segs)
                for s, e, t in short:
                    dropped["unusable_length"] += (e - s) / 60
                for s, e, t in clips:
                    a, b = int(s * SR), min(int(e * SR), len(x))
                    if b - a < 3 * SR:  # a clip cut by the end of the block
                        dropped["unusable_length"] += (b - a) / SR / 60
                        continue
                    secs = (b - a) / SR
                    why = judge(S, x[a:b], den[a:b], nrm[a:b], t, refs, thr)
                    if why:
                        dropped[why] += secs / 60
                        if len(rejected) < 3 and why not in [r["reason"] for r in rejected]:
                            rp = os.path.join(dsdir, "rejected", f"{len(rejected)}-{why}.wav")
                            os.makedirs(os.path.dirname(rp), exist_ok=True)
                            S.write_wav(rp, nrm[a:b], SR)
                            rejected.append({"path": rp, "reason": why})
                        continue
                    n_clip += 1
                    cp = os.path.join(dsdir, "clips", f"{n_clip:05d}.wav")
                    S.write_wav(cp, nrm[a:b], SR)
                    rows.append({"id": f"c{n_clip:05d}", "audio_path": cp, "text": t.strip(), "language_id": lang or lang_hint or "en"})
                    kept_s += secs
                    langs[lang or lang_hint or "en"] = langs.get(lang or lang_hint or "en", 0) + secs
        except Cancelled:
            raise
        except Exception as e:
            failed += 1
            print(f"pro scan: skipped {path}: {type(e).__name__}", file=sys.stderr, flush=True)
    if not rows:
        raise S.bad("No usable speech from this speaker was found in that folder. Check it holds clean recordings of this voice, then scan again.")
    dev_n = min(max(3, math.ceil(0.05 * len(rows))), len(rows) // 2)
    dev_ids = set(random.Random(7).sample(range(len(rows)), dev_n)) if dev_n else set()
    for name, sel in (("train", [r for i, r in enumerate(rows) if i not in dev_ids]), ("dev", [r for i, r in enumerate(rows) if i in dev_ids])):
        with open(os.path.join(dsdir, f"{name}.jsonl"), "w") as f:
            f.write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in sel))
    result = {"dataset_id": ds, "files_total": len(files), "files_failed": failed, "kept_minutes": round(kept_s / 60, 2),
              "dropped_minutes": round(sum(dropped.values()), 2), "dropped": {k: round(v, 2) for k, v in dropped.items()},
              "samples": [r["audio_path"] for r in random.Random(3).sample(rows, min(5, len(rows)))],
              "rejected_samples": rejected, "enough": kept_s / 60 >= ENOUGH_MIN,
              "threshold": thr, "language": max(langs, key=langs.get) if langs else lang_hint,
              "clips": len(rows), "dev_clips": dev_n}
    write_json(os.path.join(dsdir, "scan.json"), result)
    return result


def start_scan(S, body):
    S.not_training()
    vid = S.text_arg(body, "voice_id")
    S.load_voice(vid)
    folder = S.text_arg(body, "folder")
    if not os.path.isabs(folder) or not os.path.isdir(folder):
        raise S.bad("Kitflo couldn't find that folder. Choose it again.")
    jid, j = S.new_job("Looking through the folder")
    cancel = S.CANCEL[jid] = threading.Event()

    def run():
        try:
            j.update(state="done", progress=1.0, message="Done", result=scan(S, j, cancel, vid, folder))
        except Cancelled:
            j.update(state="failed", error="Scan cancelled.")
        except Exception as e:
            S.fail_job(j, e, "Scanning failed unexpectedly. Try a smaller folder, or scan again.")
        finally:
            S.CANCEL.pop(jid, None)
            S.unload_whisper()
            S.unload_small()

    threading.Thread(target=run, daemon=True).start()
    return {"job_id": jid}


# ---------------------------------------------------------------- train (server side)

def start_train(S, body):
    vid = S.text_arg(body, "voice_id")
    v = S.load_voice(vid)
    ds = S.text_arg(body, "dataset_id")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", ds):
        raise S.bad("That dataset id isn't valid. Scan the folder again.")
    dsdir = pro_dir(S, vid, "datasets", ds)
    try:
        info = json.load(open(os.path.join(dsdir, "scan.json")))
    except OSError:
        raise S.ApiError(404, "That dataset doesn't exist any more. Scan the folder again.")
    steps = body.get("steps")
    if steps is None:
        steps = min(max(round(info["kept_minutes"] * 60), 300), 3000)
    if isinstance(steps, bool) or not isinstance(steps, int) or not 10 <= steps <= 20000:
        raise S.bad("Steps must be a whole number between 10 and 20,000.")
    with TRAIN_LOCK:
        if S.STATE["status"] != "ready":
            raise S.ApiError(409, "The voice engine isn't ready (it is still loading or already training). Try again in a moment.")
        if S.GPU.locked() or any(x["state"] == "running" for x in S.JOBS.values()):
            raise S.ApiError(409, "Another voice job is running. Wait for it to finish, then start training.")
        S.STATE["status"] = "training"  # /speak and friends now answer 409
        PRO["training"] = vid
        jid, j = S.new_job("Getting ready")
    cancel = S.CANCEL[jid] = threading.Event()
    def run():
        try:
            _train_job(S, j, cancel, v, ds, dsdir, info, steps)
        finally:
            PRO["training"] = None
            S.CANCEL.pop(jid, None)

    threading.Thread(target=run, daemon=True).start()
    return {"job_id": jid}


def _free_speaking_model(S):
    S.STATE["model"] = None
    PRO.update(base=None, pm=None, loaded=OrderedDict())
    S.unload_whisper()
    import gc
    gc.collect()
    S.free_gpu()


def _train_job(S, j, cancel, v, ds, dsdir, info, steps):
    vid = v["id"]
    tdir = pro_dir(S, vid, "train")
    ok = False
    try:
        with S.GPU:  # let any speak that slipped in finish, then hold everyone off while the model is dropped
            _free_speaking_model(S)
        shutil.rmtree(tdir, ignore_errors=True)
        os.makedirs(tdir)
        with open(os.path.join(tdir, "train.log"), "w") as log:
            proc = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "pro.py"), "train", "--out", tdir, "--dataset", dsdir, "--steps", str(steps)],
                                    env={**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1"}, stdout=log, stderr=subprocess.STDOUT)
            while proc.poll() is None:
                if cancel.is_set():
                    proc.terminate()
                    try:
                        proc.wait(20)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    raise Cancelled()
                try:
                    with open(os.path.join(tdir, "status.json")) as f:
                        st = json.load(f)
                    j["detail"] = {k: st[k] for k in ("step", "steps", "loss", "dev_loss", "eta_s", "s_per_step") if k in st}
                    j["progress"] = min(st.get("progress", 0.0), 0.9)
                    j["message"] = st.get("message", "Training")
                except (OSError, ValueError):
                    pass
                time.sleep(2)
        if proc.returncode != 0:
            with open(os.path.join(tdir, "train.log")) as f:
                tail = f.read()[-1500:]
            print("pro train failed:\n" + tail, file=sys.stderr, flush=True)
            raise RuntimeError("training process exited with an error")
        with open(os.path.join(tdir, "status.json")) as f:
            final = json.load(f)["adapter"]
        adir = pro_dir(S, vid, "adapter")
        shutil.rmtree(adir, ignore_errors=True)
        shutil.move(os.path.join(tdir, final), adir)
        shutil.rmtree(tdir, ignore_errors=True)  # optimizer state, checkpoints, logs: only the adapter is kept
        ok = True
    except Cancelled:
        j.update(state="failed", error="Training cancelled. Your voice still works without Pro.")
    except Exception as e:
        S.fail_job(j, e, "Training failed. Your voice still works without Pro; try again with fewer steps or close other apps first.")
    finally:
        shutil.rmtree(tdir, ignore_errors=True)
        j["message"], j["progress"] = "Reloading the speaking model", 0.92
        S.STATE["status"] = "loading"
        S.load_model()  # also warms the default voice
    if not ok:
        return
    try:
        j["message"], j["progress"] = "Comparing with and without Pro", 0.95
        result = ab_test(S, v, ds, info, steps)
        j.update(state="done", progress=1.0, message="Done", result=result)
    except Exception as e:
        S.fail_job(j, e, "Training finished, but the A/B check failed. Pro is saved but off; turn it on from the voice's menu.")
        with S.FILES:
            vv = S.load_voice(vid)
            vv["pro"] = {"enabled": False, "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "minutes": info["kept_minutes"], "steps": steps, "scores": None}
            S.store_voice(vv)


# ---------------------------------------------------------------- A/B

def ab_test(S, v, ds, info, steps):
    """3 fixed sentences with and without the adapter, same seeds; held-out ECAPA, UTMOS and CER for each."""
    import torch
    vid = v["id"]
    dsdir = pro_dir(S, vid, "datasets", ds)
    code = next(iter(v["languages"]))
    dev = [json.loads(l) for l in open(os.path.join(dsdir, "dev.jsonl")) if l.strip()] or [json.loads(l) for l in open(os.path.join(dsdir, "train.jsonl")) if l.strip()]
    texts = FIXED_SENTENCES if code == "en" else [r["text"][:200] for r in dev[:3]]  # other languages: dev-clip sentences, never trained on
    prompt = S.get_prompt(vid, code)
    held = [S.ecapa_embed(*sf_read(r["audio_path"])) for r in dev[:12]]
    takes = {"base": [], "pro": []}
    for tag in ("base", "pro"):  # generate everything first so Whisper and the generator are never resident together
        for k, text in enumerate(texts):
            takes[tag].append(S.speak_prompt(prompt, code, text, S.STEPS["balanced"], 1.0, 100 + k, adapter=vid if tag == "pro" else None))
    scores = {}
    mos = utmos_model()
    for tag in takes:
        sims = [S.mean_cos(S.ecapa_embed(a, SR), held) for a in takes[tag]]
        scores[tag] = {"match": round(float(np.mean(sims)), 4),
                       "utmos": round(float(np.mean([float(mos(torch.from_numpy(enhance.resample(a, SR, 16000))[None], 16000)) for a in takes[tag]])), 3) if mos else None}
    del mos
    import gc
    gc.collect()
    for tag in takes:
        scores[tag]["cer"] = round(float(np.mean([S.cer(t, S.transcribe(a, SR, code)[0]) for t, a in zip(texts, takes[tag])])), 4)
    S.unload_whisper()
    S.unload_small()
    abdir = pro_dir(S, vid, "ab")
    shutil.rmtree(abdir, ignore_errors=True)
    os.makedirs(abdir)
    pairs = []
    for k, text in enumerate(texts, 1):  # A/B in random order per sentence, so listening is blind; k is 1-based like the file names
        pro_side = "A" if random.random() < 0.5 else "B"
        for side in "AB":
            S.write_wav(os.path.join(abdir, f"{side}-{k}.wav"), takes["pro" if side == pro_side else "base"][k - 1], SR)
        pairs.append({"k": k, "text": text, "pro": pro_side})
    write_json(pro_dir(S, vid, "ab.json"), {"pairs": pairs, "scores": scores, "language": code})
    worse = scores["pro"]["match"] < scores["base"]["match"] - 0.02
    with S.FILES:
        vv = S.load_voice(vid)
        vv["pro"] = {"enabled": not worse, "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "minutes": info["kept_minutes"], "steps": steps, "scores": scores}
        S.store_voice(vv)
    return {"voice": vv, "scores": scores, "ab_dir": abdir, "pairs": pairs}


def sf_read(path):
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    return x.mean(axis=1), sr


def utmos_model():
    """UTMOS22 strong from torch hub (cached after first use); None if it can't be loaded, so A/B still reports match and CER."""
    try:
        import torch
        return torch.hub.load("tarepan/SpeechMOS:v1.2.0", "utmos22_strong", trust_repo=True).eval()
    except Exception as e:
        print(f"UTMOS unavailable: {type(e).__name__}", file=sys.stderr, flush=True)
        return None


# ---------------------------------------------------------------- adapters (PEFT, never merged)

PRO = {"base": None, "pm": None, "loaded": OrderedDict(), "training": None}  # loaded: voice id -> adapter mtime, oldest first
TRAIN_LOCK = threading.Lock()  # /pro/train's check-and-set
MAX_ADAPTERS = 2


def has_adapter(S, v):
    return bool((v.get("pro") or {}).get("enabled")) and os.path.isfile(os.path.join(S.vdir(v["id"]), "pro", "adapter", "adapter_model.safetensors"))


def activate(S, vid):
    """Context manager for one generation. vid=None means base weights. Call under the GPU lock."""
    m = S.STATE["model"]
    if PRO["base"] is not m:
        PRO.update(base=m, pm=None, loaded=OrderedDict())
    if vid is None:
        # disable_adapter() needs a live adapter: PEFT keeps a deleted name as active_adapter and then raises KeyError
        return PRO["pm"].disable_adapter() if PRO["pm"] is not None and PRO["loaded"] else contextlib.nullcontext()
    path = pro_dir(S, vid, "adapter")
    mt = os.path.getmtime(os.path.join(path, "adapter_model.safetensors"))
    if PRO["loaded"].get(vid) != mt:
        drop(vid)
        while len(PRO["loaded"]) >= MAX_ADAPTERS:
            drop(next(iter(PRO["loaded"])))
        from peft import PeftModel
        if PRO["pm"] is None:
            PRO["pm"] = PeftModel.from_pretrained(m, path, adapter_name=vid, is_trainable=False)
        else:
            PRO["pm"].load_adapter(path, adapter_name=vid)
        PRO["loaded"][vid] = mt
    PRO["loaded"].move_to_end(vid)
    PRO["pm"].set_adapter(vid)
    return contextlib.nullcontext()


def drop(vid):
    if vid in PRO["loaded"] and PRO["pm"] is not None:
        try:
            PRO["pm"].delete_adapter(vid)
        except Exception as e:
            print(f"adapter {vid} could not be unloaded: {type(e).__name__}", file=sys.stderr, flush=True)
    PRO["loaded"].pop(vid, None)
    if not PRO["loaded"]:
        PRO["pm"] = None


def delete_pro(S, vid):
    if PRO.get("training") == vid:
        raise S.ApiError(409, "Your voice is training. Cancel it first, or wait for it to finish.")
    with S.FILES:
        v = S.load_voice(vid)
        with S.GPU:  # unload and delete in one step so nothing can generate with files that are going away
            drop(vid)
            for sub in ("adapter", "ab", "datasets"):
                shutil.rmtree(pro_dir(S, vid, sub), ignore_errors=True)
            if os.path.exists(pro_dir(S, vid, "ab.json")):
                os.remove(pro_dir(S, vid, "ab.json"))
        v.pop("pro", None)
        S.store_voice(v)
        return v


def set_enabled(S, vid, enabled):
    with S.FILES:
        v = S.load_voice(vid)
        if not v.get("pro"):
            raise S.bad("This voice hasn't been trained with Pro yet.")
        v["pro"]["enabled"] = bool(enabled)
        S.store_voice(v)
        return v


# ---------------------------------------------------------------- train (child process)

def child_train(a):
    """Runs in its own process: tokenize the dataset, train a LoRA with the upstream OmniVoice recipe on MPS, save adapters."""
    import warnings
    warnings.filterwarnings("ignore")
    import torch
    from torch.utils.data import DataLoader
    from transformers import AutoFeatureExtractor, AutoTokenizer, HiggsAudioV2TokenizerModel, get_cosine_schedule_with_warmup
    from peft import LoraConfig, get_peft_model
    from omnivoice.data.batching import StreamLengthGroupDataset
    from omnivoice.data.collator import PaddingDataCollator
    from omnivoice.data.dataset import IterableDataReader
    from omnivoice.data.processor import OmniVoiceSampleProcessor
    from omnivoice.models.omnivoice import OmniVoice, _resolve_model_path

    out, steps = a.out, a.steps

    def mem(tag):
        if os.environ.get("KITFLO_PRO_DEBUG"):
            import resource
            print(f"MEM {tag}: mps alloc {torch.mps.current_allocated_memory()/2**30:.2f} GB, driver {torch.mps.driver_allocated_memory()/2**30:.2f} GB, rss {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/2**30:.2f} GB", flush=True)
    torch.manual_seed(42)
    t_start = time.time()

    def status(**kw):
        write_json(os.path.join(out, "status.json"), kw)

    def rows(name):
        p = os.path.join(a.dataset, f"{name}.jsonl")
        return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []

    train_rows, dev_rows = rows("train"), rows("dev")
    ckpt = _resolve_model_path("k2-fsa/OmniVoice")

    # 1. Tokenize with OmniVoice's audio tokenizer. Upstream hard-codes CPU without CUDA; try MPS, fall back to CPU.
    tok_path = os.path.join(ckpt, "audio_tokenizer")
    if not os.path.isdir(tok_path):
        tok_path = _resolve_model_path("eustlb/higgs-audio-v2-tokenizer")
    fe = AutoFeatureExtractor.from_pretrained(tok_path)
    device = "mps"
    try:
        tokenizer_model = HiggsAudioV2TokenizerModel.from_pretrained(tok_path, device_map="mps")
    except Exception:
        device = "cpu"
        tokenizer_model = HiggsAudioV2TokenizerModel.from_pretrained(tok_path, device_map="cpu")

    def encode(path):
        x, sr = sf.read(path, dtype="float32", always_2d=True)
        x = enhance.resample(x.mean(axis=1), sr, SR)
        x = x / (np.abs(x).max() + 1e-7) * 0.9  # same peak normalisation as upstream's data pipeline
        with torch.inference_mode():
            inp = fe(raw_audio=x, sampling_rate=SR, return_tensors="pt").to(tokenizer_model.device)
            return tokenizer_model.encode(inp["input_values"]).audio_codes.squeeze(0).to(torch.int16).cpu()

    def tokenize(rs, label):
        out_rows = []
        for i, r in enumerate(rs):
            if os.getppid() == 1:  # the server died: don't keep tokenizing headless
                sys.exit(4)
            nonlocal device, tokenizer_model
            try:
                tokens = encode(r["audio_path"])
            except Exception:
                if device == "mps":  # the tokenizer's conv has more output channels than MPS supports on some versions
                    device = "cpu"
                    tokenizer_model = HiggsAudioV2TokenizerModel.from_pretrained(tok_path, device_map="cpu")
                    tokens = encode(r["audio_path"])
                else:
                    raise
            out_rows.append({"audio_tokens": tokens, "label": {**r, "num_tokens": tokens.shape[1]}})
            status(phase="tokenizing", message=f"Preparing {label} audio ({i + 1}/{len(rs)})", progress=0.02 * (i + 1) / max(len(rs), 1), step=0, steps=steps)
        return out_rows

    train_samples, dev_samples = tokenize(train_rows, "training"), tokenize(dev_rows, "dev")
    mem("after tokenizing")
    del tokenizer_model, fe
    import gc
    gc.collect()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()
    mem("tokenizer freed")

    # 2. Model: float32 base, sdpa attention (no flex), LoRA r=16 on the LLM projections; audio embeddings/heads fully trained.
    text_tok = AutoTokenizer.from_pretrained(ckpt)
    if text_tok.pad_token is None:
        text_tok.pad_token = text_tok.eos_token
    model = OmniVoice.from_pretrained(ckpt, attn_implementation="sdpa", dtype=torch.float32, train=True)
    if len(text_tok) != model.config.llm_config.vocab_size:
        model.llm.resize_token_embeddings(len(text_tok))
        model.config.llm_config.vocab_size = len(text_tok)
    model.config.pad_token_id, model.config.bos_token_id, model.config.eos_token_id = text_tok.pad_token_id, text_tok.bos_token_id, text_tok.eos_token_id
    model = get_peft_model(model, LoraConfig(
        r=16, lora_alpha=32, lora_dropout=0.05, bias="none",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        modules_to_save=["audio_embeddings", "audio_heads"]))
    model.base_model.model.llm.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})  # ~3 GB less activation memory for ~25% more time
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model.to(dev)
    mem("model on device")

    # 3. Our own dataloaders (upstream's hard-code pin_memory=True / prefetch / worker processes, none of which work on MPS).
    class Reader(IterableDataReader):
        sample_rate = SR

        def __init__(self, samples, shuffle):
            self.samples, self.shuffle, self.epoch = samples, shuffle, 0

        def set_epoch(self, e):
            self.epoch = e

        def __iter__(self):
            order = list(range(len(self.samples)))
            if self.shuffle:
                random.Random(self.epoch).shuffle(order)
            return iter([self.samples[i] for i in order])

        def __len__(self):
            return len(self.samples)

    proc = OmniVoiceSampleProcessor(text_tokenizer=text_tok, num_channels=8, audio_mask_id=1024, prompt_ratio_range=(0.0, 0.3),
                                    mask_ratio_range=(0.0, 1.0), drop_cond_ratio=0.1, language_ratio=0.8, use_pinyin_ratio=0.0,
                                    instruct_ratio=0.0, only_instruct_ratio=0.0)

    def loader(samples, shuffle):
        ds = StreamLengthGroupDataset(Reader(samples, shuffle), batch_duration=BATCH_TOKENS, min_length=50, max_length=2000, max_sample=64,
                                      processor=proc, length_fn=lambda s: s["length"])
        return ds, DataLoader(ds, batch_size=None, num_workers=0, collate_fn=PaddingDataCollator(proc, BATCH_TOKENS), pin_memory=False)

    train_ds, train_loader = loader(train_samples, True)
    dev_loader = loader(dev_samples, False)[1] if dev_samples else None

    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=1e-4, weight_decay=0.01)
    sched = get_cosine_schedule_with_warmup(opt, math.ceil(steps * 0.05), steps)

    def to_dev(b):
        return {k: v.to(dev) if isinstance(v, torch.Tensor) else v for k, v in b.items()}

    def evaluate():
        model.eval()
        losses = []
        with torch.no_grad(), torch.autocast(dev.type, dtype=torch.bfloat16):
            for b in dev_loader:
                losses.append(model(**to_dev(b)).loss.float().item())
        model.train()
        return float(np.mean(losses)) if losses else None

    def save(name):
        model.save_pretrained(os.path.join(out, name))

    # 4. Train. Checkpoint (adapter only) every 250 steps and at the end; keep the best by dev loss plus the last.
    model.train()
    epoch, it, best, dev_loss, loss_v, times = 0, iter(train_loader), None, None, 0.0, []
    for step in range(1, steps + 1):
        if os.getppid() == 1:  # the server died: don't keep training headless
            sys.exit(4)
        try:
            batch = next(it)
        except StopIteration:
            epoch += 1
            train_ds.set_epoch(epoch)
            it = iter(train_loader)
            batch = next(it)
        t0 = time.time()
        with torch.autocast(dev.type, dtype=torch.bfloat16):
            loss = model(**to_dev(batch)).loss
        if step <= 2:
            mem(f"step {step} forward")
        loss.backward()
        if step <= 2:
            mem(f"step {step} backward")
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        sched.step()
        opt.zero_grad()
        loss_v = float(loss.detach().float())
        times = (times + [time.time() - t0])[-10:]
        sps = float(np.mean(times))
        if step % 250 == 0 or step == steps:
            if dev_loader is not None:
                dev_loss = evaluate()
                if dev_loss is not None and (best is None or dev_loss < best):
                    best = dev_loss
                    shutil.rmtree(os.path.join(out, "best"), ignore_errors=True)
                    save("best")
            shutil.rmtree(os.path.join(out, "last"), ignore_errors=True)
            save("last")
        status(phase="training", message=f"Training, step {step} of {steps}", progress=0.02 + 0.88 * step / steps, step=step, steps=steps,
               loss=round(loss_v, 4), dev_loss=None if dev_loss is None else round(dev_loss, 4), s_per_step=round(sps, 2), eta_s=round(sps * (steps - step)))
    status(phase="done", message="Training finished", progress=0.9, step=steps, steps=steps, loss=round(loss_v, 4), dev_loss=dev_loss,
           adapter="best" if os.path.isdir(os.path.join(out, "best")) else "last", seconds=round(time.time() - t_start))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["train"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--steps", type=int, required=True)
    a = ap.parse_args()
    try:
        child_train(a)
    except SystemExit:
        raise
    except BaseException:
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
