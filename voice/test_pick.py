"""Plain `python test_pick.py`: picker returns 3-10 s on sentence boundaries; falls back without sentences."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
from pick import chunks, pick

SEGMENTS = [(0.0, 8.38, "a"), (8.38, 16.88, "b"), (17.16, 24.3, "c"), (24.3, 32.32, "d"),
            (32.32, 36.72, "e"), (37.68, 42.24, "f"), (42.58, 45.22, "g")]

r = pick(SEGMENTS, 46.0)
assert not r["fallback"] and 3 <= r["end"] - r["start"] <= 10, r
assert any(s == r["start"] for s, _, _ in SEGMENTS) and any(e == r["end"] for _, e, _ in SEGMENTS), r

r = pick([], 20.0)  # no sentences at all
assert r["fallback"] and 3 <= r["end"] - r["start"] <= 10, r
r = pick([(0.0, 25.0, "one very long sentence")], 25.0)  # nothing fits 3-10 s
assert r["fallback"] and r["end"] - r["start"] <= 10, r

long_b = "B" * 400
c = chunks("A. " + long_b)  # a long sentence after a short one: nothing lost, nothing reordered, nothing over the limit
assert c[0] == "A." and "".join(c[1:]) == long_b and all(len(x) <= 300 for x in c), c
cjk = "你好，今天天气很好。" * 60
c = chunks(cjk)
assert len(c) > 1 and "".join(c).replace(" ", "") == cjk and all(len(x) <= 300 for x in c), c
assert chunks("It costs 3.5 dollars. Fine.") == ["It costs 3.5 dollars. Fine."]
print("test_pick OK")
