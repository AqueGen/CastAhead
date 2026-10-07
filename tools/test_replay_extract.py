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
