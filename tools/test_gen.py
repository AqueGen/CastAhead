"""Checks for the estimators in gen.py: python tools/test_gen.py"""
import os, random, tempfile

from gen import densest, read_anchor, rotation, settle, targeted, threat


def test_targeted_needs_a_clear_majority_and_samples():
    assert targeted(None) is None
    assert targeted([4, 4]) is None
    assert targeted([40, 39]) is True
    assert targeted([40, 1]) is False
    assert targeted([40, 20]) is None


def row(**fields):
    base = dict(spell=1, npc=2, mob="Mob", name="Bolt", cast=2.5, cd=[20.0], first=5.0, firstN=10,
                offset=0.0, hits=1.0, dmg=0.3, kick=0.1, cc=0.05, samples=100, level=90,
                approx=False, filler=False, kickable=False, channel=False, fit=0.9, mdt_kick=None)
    base.update(fields)
    return base


def test_small_drift_keeps_the_anchor():
    old = row()
    new = row(cast=2.6, cd=[20.4], first=6.5, firstN=15, offset=0.8, hits=1.5, dmg=0.35, kick=0.15, cc=0.1,
              samples=180)
    settled, changed = settle(new, old)
    assert changed == []
    assert {k: settled[k] for k in old} == old


def test_crossing_an_in_game_threshold_updates():
    settled, changed = settle(row(kick=0.28), row(kick=0.2))
    assert changed == ["kick", "kickable"] and settled["kickable"]
    _, changed = settle(row(kick=0.26), row(kick=0.2))
    assert changed == []


def test_cooldown_compared_as_a_cycle():
    _, changed = settle(row(cd=[20.0, 20.2]), row(cd=[20.0]))
    assert changed == []
    _, changed = settle(row(cd=[20.0, 27.0]), row(cd=[20.0]))
    assert changed == ["cd"]


def test_approx_needs_a_margin_to_flip():
    settled, _ = settle(row(fit=0.48), row(approx=False))
    assert not settled["approx"]
    settled, _ = settle(row(fit=0.44), row(approx=False))
    assert settled["approx"]


def test_anchor_reads_back_what_gen_writes():
    line = ('        { spell = 7, npc = 8, mob = "Mob", name = "Bolt", cast = 2.5, cd = { 3.6, 9.7 }, first = -0.5,'
            ' hits = nil, dmg = 0.2, kick = 0.41, cc = 0.0, n = 12, firstN = 3, level = nil, offset = 1.0,'
            ' kickable = true, filler = true, targeted = false, },\n')
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as f:
        f.write('CastAheadData = {\n    [9] = { name = "Zone",\n' + line + "    },\n}\n")
    try:
        rows, zones = read_anchor(f.name)
    finally:
        os.unlink(f.name)
    r = rows[(9, 7, 8)]
    assert zones == {9: "Zone"}
    assert r["cd"] == [3.6, 9.7] and r["first"] == -0.5 and r["hits"] is None and r["samples"] == 12
    assert r["kickable"] and r["filler"] and not r["approx"] and r["level"] is None
    assert r["targeted"] is False


def test_densest_ignores_sample_order():
    xs = [10.0, 10.2, 10.4, 20.0, 20.2, 20.4]
    for _ in range(20):
        random.shuffle(xs)
        assert densest(xs, 0.5) == densest(sorted(xs), 0.5)


def test_densest_takes_the_bigger_mode():
    assert densest([2.4, 2.5, 14.0, 14.1, 14.2], 1.0) == (14.1, 3)


def test_densest_without_a_repeat_falls_back_to_the_median():
    assert densest([3.0, 9.0, 15.0], 0.5) == (9.0, 1)


def test_densest_never_writes_negative_zero():
    value, _ = densest([-0.1, 0.0, 0.0, 0.1], 0.5)
    assert str(value) == "0.0"


def test_rotation_ignores_sequences_restarted_after_a_miss():
    fresh = {"a@0#0": [5.0, 9.0, 5.0, 9.0], "b@0#0": [5.0, 9.0, 5.0], "c@0#0": [5.0, 9.0, 5.0, 9.0]}
    broken = {"a@0#1": [9.0, 5.0, 9.0], "b@0#1": [9.0, 5.0, 9.0], "c@0#1+": [9.0, 5.0]}
    assert rotation({**fresh, **broken}, 7.0) == [5.0, 9.0]


def test_rotation_that_predicts_no_better_than_one_cooldown_collapses():
    runs = {"a@0#0": [29.1, 29.1, 34.0], "b@0#0": [29.1, 33.8, 29.1], "c@0#0": [29.2, 29.1, 34.0]}
    assert rotation(runs, 29.1) == [29.1]


def test_damage_needs_three_samples():
    rec = {"hits": [1], "dmg": [1.4], "cast": [5.0], "kicked": 0, "starts": 1}
    assert threat(rec)["dmg"] is None
    rec.update(hits=[1, 2, 2], dmg=[0.3, 0.4, 0.5], cast=[5.0] * 3, starts=3)
    t = threat(rec)
    assert t["dmg"] == 0.4 and t["hits"] == 2.0


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("OK")
