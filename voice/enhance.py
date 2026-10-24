"""Audio enhancement: `clean` (denoise + loudness) and `studio` (clean + EQ + compression)."""
import threading
import warnings

import numpy as np
import pyloudnorm as pyln
from scipy import signal

warnings.filterwarnings("ignore")  # torchaudio deprecation noise from `df`

TARGET_LUFS = -16.0
PEAK_DB = -1.0
_df = None  # (model, state), loaded on first use
_lock = threading.Lock()  # one load, and DeepFilterNet's state isn't safe to share between requests


def lufs(x, sr):
    return float(pyln.Meter(sr).integrated_loudness(x)) if len(x) > sr * 0.4 else -70.0


def resample(x, sr, to):
    if sr == to:
        return x
    g = np.gcd(int(sr), int(to))
    return signal.resample_poly(x, to // g, sr // g).astype(np.float32)


def normalize(x, sr):
    """Gain to -16 LUFS, then limit peaks to -1 dBFS (a plain scale-down would undershoot the loudness)."""
    for _ in range(2):  # the limiter eats some loudness; one correction pass wins it back
        l = lufs(x, sr)
        if l > -69:
            x = limit_peak(x * 10 ** ((TARGET_LUFS - l) / 20), sr=sr)
    return x


def limit_peak(x, db=PEAK_DB, sr=24000):
    """Smoothed gain-reduction limiter (5 ms look-ahead), then a hard clip as the safety net."""
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    ceiling = 10 ** (db / 20)
    gain = np.minimum(1.0, ceiling / np.maximum(np.abs(x), 1e-9))
    w = max(int(sr * 0.005), 1)
    gain = uniform_filter1d(minimum_filter1d(gain, 2 * w + 1), 2 * w + 1)
    return np.clip(x * gain, -ceiling, ceiling).astype(np.float32)


def denoise(x, sr):
    """DeepFilterNet 3 (runs at 48 kHz, on CPU: ~1.3 s for 46 s of audio)."""
    global _df
    import torch
    from df.enhance import enhance, init_df
    with _lock:
        if _df is None:
            model, state, _ = init_df()
            _df = (model, state)
        model, state = _df
        y = enhance(model, state, torch.from_numpy(resample(x, sr, 48000))[None])
    return resample(y[0].numpy(), 48000, sr)


def unload():
    global _df
    with _lock:
        _df = None


def _peaking(f0, gain_db, q, sr):
    """RBJ peaking-EQ biquad as second-order sections."""
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * f0 / sr
    al = np.sin(w) / (2 * q)
    b = [1 + al * a, -2 * np.cos(w), 1 - al * a]
    d = [1 + al / a, -2 * np.cos(w), 1 - al / a]
    return signal.tf2sos(np.array(b) / d[0], np.array(d) / d[0])


def _compress(x, sr, thresh_db=-24.0, ratio=2.0, attack=0.01, release=0.15):
    """Light block-wise feed-forward compressor (10 ms blocks, smoothed gain)."""
    n = int(sr * 0.01)
    blocks = len(x) // n
    if blocks < 2:
        return x
    rms = np.sqrt(np.mean(x[: blocks * n].reshape(blocks, n) ** 2, axis=1) + 1e-12)
    over = np.maximum(20 * np.log10(rms) - thresh_db, 0)
    target = -over * (1 - 1 / ratio)
    g, out = 0.0, np.empty(blocks)
    for i, t in enumerate(target):
        c = np.exp(-0.01 / (attack if t < g else release))
        g = c * g + (1 - c) * t
        out[i] = g
    gain = 10 ** (np.interp(np.arange(len(x)), (np.arange(blocks) + 0.5) * n, out) / 20)
    return (x * gain).astype(np.float32)


def process(x, sr, level="clean"):
    """Return (enhanced float32 mono at the same rate, before_lufs, after_lufs)."""
    x = np.asarray(x, dtype=np.float32)
    if x.ndim > 1:
        x = x.mean(axis=1)
    before = lufs(x, sr)
    y = denoise(x, sr)
    if level == "studio":
        y = signal.sosfilt(signal.butter(2, 80, "highpass", fs=sr, output="sos"), y)
        y = signal.sosfilt(_peaking(3000, 2.0, 0.9, sr), y).astype(np.float32)
        y = _compress(y, sr)
    y = normalize(y, sr)
    return y, before, lufs(y, sr)
