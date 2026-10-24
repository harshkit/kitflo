"""Pure helpers: the passage picker (best 3-10 s run of whole sentences from Whisper segments) and the text chunker."""
import re



def pick(sentences, total, score=None, lo=3.0, hi=10.0):
    """sentences: [(start, end, text)] sorted. score(start, end) -> float, higher is better.
    Returns {"start", "end", "fallback"}; fallback=True means no sentence-aligned run fit,
    so the span is the best fixed window and the caller should warn about quality."""
    if score is None:  # default: seconds of actual speech inside the span
        score = lambda a, b: sum(min(e, b) - max(s, a) for s, e, _ in sentences if e > a and s < b)
    best = None
    for i in range(len(sentences)):
        for j in range(i, len(sentences)):
            a, b = sentences[i][0], sentences[j][1]
            if b - a > hi:
                break
            if b - a >= lo and (best is None or score(a, b) > best[0]):
                best = (score(a, b), a, b)
    if best:
        return {"start": best[1], "end": best[2], "fallback": False}
    n = min(8.0, total)  # ponytail: fixed 8 s windows at 0.5 s steps; cut at word gaps if this proves too crude
    starts = [k * 0.5 for k in range(int(max(total - n, 0) / 0.5) + 1)]
    a = max(starts, key=lambda t: score(t, t + n))
    return {"start": a, "end": a + n, "fallback": True}


SENTENCE_END = re.compile(r"(?<=[.!?…])\s+|(?<=[।。！？])\s*")  # ASCII '.' needs a space after it, so "3.5" stays whole


def chunks(text, limit=300):
    """Split text into pieces of at most `limit` characters, on sentence ends where possible. Order is preserved."""
    out, cur = [], ""
    for p in (s.strip() for s in SENTENCE_END.split(text.strip())):
        if not p:
            continue
        if len(p) > limit:  # one huge sentence: flush, then cut at the last space/comma before the limit
            if cur:
                out.append(cur)
                cur = ""
            while len(p) > limit:
                k = max(p.rfind(" ", 0, limit), p.rfind(",", 0, limit) + 1)
                k = k if k > 0 else limit
                out.append(p[:k].strip())
                p = p[k:].strip()
        if cur and len(cur) + len(p) + 1 > limit:
            out.append(cur)
            cur = p
        else:
            cur = f"{cur} {p}".strip()
    return [c for c in out + [cur] if c]
