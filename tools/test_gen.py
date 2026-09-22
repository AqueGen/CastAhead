"""Checks for the estimators in gen.py: python tools/test_gen.py"""
import contextlib, io, json, os, random, tempfile

from gen import choose_targeted, densest, main as gen_main, read_anchor, rotation, settle, targeted, threat


def test_the_game_overrules_the_log_and_a_channel_needs_the_game():
    assert choose_targeted([40, 40], [3, 0], False) is False
    assert choose_targeted([40, 40], None, False) is True
    assert choose_targeted([40, 40], None, True) is None
    assert choose_targeted([40, 40], [2, 0], True) is None
    assert choose_targeted([40, 0], [16, 15], False) is None


def test_targeted_needs_a_clear_majority_and_samples():
    assert targeted(None) is None
    assert targeted([4, 4]) is None
    assert targeted([40, 39]) is True
    assert targeted([40, 1]) is False
    assert targeted([40, 20]) is None


def row(**fields):
    base = dict(spell=1, npc=2, mob="Mob", name="Bolt", cast=2.5, cd=[20.0], first=5.0, firstN=10,
                offset=0.0, hits=1.0, dmg=0.3, kick=0.1, cc=0.05, samples=100, level=90,
                approx=False, filler=False, kickable=False, channel=False, fit=0.9, mdt_kick=None,
                targeted=None)
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


def test_a_cooldown_drifting_one_delay_step_keeps_the_anchor():
    _, changed = settle(row(cd=[21.5]), row(cd=[20.0]))
    assert changed == []
    _, changed = settle(row(cd=[24.0]), row(cd=[20.0]))
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


def _base_cast_record(**overrides):
    r = dict(cast=[2.6, 2.6, 2.6, 2.6, 2.6], iv=[], first=[], name="Bolt", mob="Mob",
              hits=[], dmg=[], kicked=0, starts=0)
    r.update(overrides)
    return r


def _run_gen(tmp, casts, spell_times=None, channels=None, overrides=None):
    """Write the given fixtures to tmp and run gen.main; returns (Data.lua text, printed output)."""
    casts_path, out_path = os.path.join(tmp, "casts.json"), os.path.join(tmp, "Data.lua")
    json.dump(casts, open(casts_path, "w", encoding="utf-8"))
    paths = {}
    for name, value in (("spell_times", spell_times), ("channels", channels), ("overrides", overrides)):
        if value is not None:
            paths[name] = os.path.join(tmp, name + ".json")
            json.dump(value, open(paths[name], "w", encoding="utf-8"))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        gen_main(casts_path, out_path, None, paths.get("overrides"), paths.get("channels"), None, None,
                  paths.get("spell_times"))
    return open(out_path, encoding="utf-8").read(), buf.getvalue()


def test_log_measured_cast_wins_when_the_log_saw_enough_starts_but_reports_the_disagreement():
    with tempfile.TemporaryDirectory() as tmp:
        casts = {"1|Zone": {"10": {"1000": _base_cast_record(starts=5)}}}
        lua, out = _run_gen(tmp, casts, spell_times={"1000": {"cast": 3.5, "channel": None}},
                            overrides={"include": ["1000"]})
        assert "cast = 2.6" in lua and "channel = true" not in lua
        assert "1000" in out and "3.5" in out and "2.6" in out


def test_client_channel_replaces_channels_json_when_the_log_saw_no_start_at_all():
    with tempfile.TemporaryDirectory() as tmp:
        casts = {"1|Zone": {"10": {"1000": _base_cast_record(cast=[], starts=0)}}}
        lua, _ = _run_gen(tmp, casts, spell_times={"1000": {"cast": 0, "channel": 5.0}},
                          channels={"1000": 99.0}, overrides={"include": ["1000"]})
        assert "cast = 5.0" in lua and "channel = true" in lua


def test_client_cast_with_no_start_at_all_is_a_triggered_cast_and_keeps_todays_behaviour():
    with tempfile.TemporaryDirectory() as tmp:
        casts = {"1|Zone": {"10": {"1000": _base_cast_record(starts=0)}}}
        with_client, out = _run_gen(tmp, casts, spell_times={"1000": {"cast": 3.5, "channel": None}},
                                    overrides={"include": ["1000"]})
        without_client, _ = _run_gen(tmp, casts, overrides={"include": ["1000"]})
        assert with_client == without_client
        assert "cast = 2.6" in with_client
        assert "disagrees" not in out


def test_spell_absent_from_client_data_keeps_todays_behaviour():
    with tempfile.TemporaryDirectory() as tmp:
        casts = {"1|Zone": {"10": {"1000": _base_cast_record()}}}
        without, _ = _run_gen(tmp, casts, overrides={"include": ["1000"]})
        with_other, _ = _run_gen(tmp, casts, spell_times={"999": {"cast": 9.9, "channel": None}},
                                 overrides={"include": ["1000"]})
        assert without == with_other


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
