"""Checks for the estimators in gen.py: python tools/test_gen.py"""
import random

from gen import densest, rotation, threat


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
