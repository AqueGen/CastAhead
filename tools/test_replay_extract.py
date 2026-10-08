from replay_extract import scan

MOB = "Creature-0-4240-2521-17579-190206-0001C697CE"


def success(stamp, spell, name):
    f = ["SPELL_CAST_SUCCESS", MOB, '"Ashseer Flamelasher"', "0xa48", "0x0", "0000000000000000", "nil", "0x0", "0x0",
         str(spell), '"%s"' % name, "0x4"] + ["0"] * 20
    f[22], f[30] = "1", "90"
    return "10/7/2026 22:%s  %s" % (stamp, ",".join(f))


def removed(stamp, spell, name):
    return "10/7/2026 22:%s  SPELL_AURA_REMOVED,%s,\"Ashseer Flamelasher\",0xa48,0x0,%s,\"Ashseer Flamelasher\",0xa48,0x0,%d,\"%s\",0x4,BUFF" % (
        stamp, MOB, MOB, spell, name)


def tick(stamp, spell, name):
    return "10/7/2026 22:%s  SPELL_DAMAGE,%s,\"Ashseer Flamelasher\",0xa48,0x0,Player-1-AAAA,\"P\",0x512,0x0,%d,\"%s\",0x4" % (
        stamp, MOB, spell, name)


def test_a_channel_ends_at_its_last_tick_when_that_comes_after_its_aura_left(tmp_path):
    log = [
        "10/7/2026 22:05:00.000  CHALLENGE_MODE_START,\"Ruby Life Pools\",2521,399,12,[10]",
        success("05:30.000", 385536, "Flaming Barrage"),
        removed("05:31.000", 385536, "Flaming Barrage"),
        tick("05:39.500", 385567, "Flaming Barrage"),
        "10/7/2026 22:09:00.000  CHALLENGE_MODE_END,2521,1,12,600000",
    ]
    path = tmp_path / "WoWCombatLog-1.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    runs = []
    scan(str(path), runs, {}, {385536: 10.0})
    ends = [e for e in runs[0].events if e["e"] == "CHANEND"]
    assert len(ends) == 1 and ends[0]["full"] is True and abs(ends[0]["t"] - 39.5) < 0.01


def start(stamp, spell, name):
    return "10/7/2026 22:%s  SPELL_CAST_START,%s,\"Ashseer Flamelasher\",0xa48,0x0,0000000000000000,nil,0x0,0x0,%d,\"%s\",0x4" % (
        stamp, MOB, spell, name)


def test_a_channel_closed_by_the_casters_next_cast_ends_there_and_is_not_full(tmp_path):
    log = [
        "10/7/2026 22:05:00.000  CHALLENGE_MODE_START,\"Ruby Life Pools\",2521,399,12,[10]",
        success("05:30.000", 385536, "Flaming Barrage"),
        start("05:32.000", 384194, "Cinderbolt"),
        "10/7/2026 22:09:00.000  CHALLENGE_MODE_END,2521,1,12,600000",
    ]
    path = tmp_path / "WoWCombatLog-1.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    runs = []
    scan(str(path), runs, {}, {385536: 10.0})
    ends = [e for e in runs[0].events if e["e"] == "CHANEND"]
    assert len(ends) == 1 and ends[0]["full"] is False and abs(ends[0]["t"] - 32.0) < 0.01


def test_a_channel_with_no_aura_or_tick_and_no_early_close_has_no_full_verdict(tmp_path):
    log = [
        "10/7/2026 22:05:00.000  CHALLENGE_MODE_START,\"Ruby Life Pools\",2521,399,12,[10]",
        success("05:30.000", 385536, "Flaming Barrage"),
        start("05:45.000", 384194, "Cinderbolt"),
        "10/7/2026 22:09:00.000  CHALLENGE_MODE_END,2521,1,12,600000",
    ]
    path = tmp_path / "WoWCombatLog-1.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    runs = []
    scan(str(path), runs, {}, {385536: 10.0})
    ends = [e for e in runs[0].events if e["e"] == "CHANEND"]
    assert len(ends) == 1 and "full" not in ends[0] and abs(ends[0]["t"] - 40.0) < 0.01


def test_a_pure_channel_replays_as_a_channel_start_and_end_marked_full_or_cut(tmp_path):
    log = [
        "10/7/2026 22:05:00.000  CHALLENGE_MODE_START,\"Ruby Life Pools\",2521,399,12,[10]",
        success("05:32.143", 385536, "Flaming Barrage"),
        removed("05:33.550", 385536, "Flaming Barrage"),
        success("06:10.000", 385536, "Flaming Barrage"),
        removed("06:20.000", 385536, "Flaming Barrage"),
        success("06:30.000", 999, "Instant Buff"),
        removed("06:45.000", 999, "Instant Buff"),
        "10/7/2026 22:09:00.000  CHALLENGE_MODE_END,2521,1,12,600000",
    ]
    path = tmp_path / "WoWCombatLog-1.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    runs = []
    scan(str(path), runs, {}, {385536: 10.0})
    events = [(e["e"], e.get("spell"), e.get("full")) for e in runs[0].events if e["e"] in ("CHAN", "CHANEND")]
    assert events == [("CHAN", 385536, None), ("CHANEND", 385536, False),
                      ("CHAN", 385536, None), ("CHANEND", 385536, True)]
