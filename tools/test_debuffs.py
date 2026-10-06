import pytest

from debuffs import gen, scan, write_review

MOB = "Creature-0-3111-2521-1-190207-0000C54473"
P1, P2, P3 = "Player-1-AAAA", "Player-1-BBBB", "Player-1-CCCC"


def stamp(*fields):
    return "10/6/2026 21:57:28.4733  " + ",".join(fields)


def start(zone="Ruby Life Pools", instance=2521):
    return stamp("CHALLENGE_MODE_START", f'"{zone}"', str(instance), "399", "12", "[10,9,147]")


def end(instance=2521):
    return stamp("CHALLENGE_MODE_END", str(instance), "1", "12", "1500000", "300.0", "300.0")


def aura(event, dst, spell=373693, kind="DEBUFF", src=MOB):
    return stamp(event, src, '"Primalist Cinderweaver"', "0x20a48", "0x80000010", dst, '"A-Realm-EU"',
                 "0x511", "0x80000000", str(spell), '"Living Bomb"', "0x4", kind)


def damage(dst, amount, maxhp, overkill=-1, absorbed=0, event="SPELL_DAMAGE"):
    f = [event, MOB, '"Mob"', "0xa48", "0x80000000", dst, '"A-Realm-EU"', "0x512", "0x80000000",
         "999", '"Hit"', "0x4"] + ["0"] * 28
    f[15], f[31], f[33], f[37] = str(maxhp), str(amount), str(overkill), str(absorbed)
    return stamp(*f)


def died(dst):
    return stamp("UNIT_DIED", "0000000000000000", "nil", "0x80000000", "0x80000000", dst, '"A-Realm-EU"',
                 "0x512", "0x80000000", "0")


def write_log(tmp_path, lines, name="WoWCombatLog-1.txt"):
    path = tmp_path / name
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(path)


LOG = [
    start(),
    aura("SPELL_AURA_APPLIED", P1),
    damage(P1, 300, 1000, absorbed=100),
    damage(P1, 200, 1000, overkill=100, event="SPELL_PERIODIC_DAMAGE"),
    aura("SPELL_AURA_REMOVED", P1),
    aura("SPELL_AURA_APPLIED", P2),
    died(P2),
    died(P3),
    aura("SPELL_AURA_APPLIED", P1, spell=111, kind="BUFF"),
    stamp("ENCOUNTER_START", "2609", '"Melidrussa"', "8", "5", "2521"),
    aura("SPELL_AURA_APPLIED", P3),
    aura("SPELL_AURA_REMOVED", P3),
    stamp("ENCOUNTER_END", "2609", '"Melidrussa"', "8", "5", "1", "60000"),
    end(),
    start(),
    aura("SPELL_AURA_APPLIED", P1),
    aura("SPELL_AURA_REMOVED", P1),
    aura("SPELL_AURA_APPLIED", P2, spell=222),
    aura("SPELL_AURA_REMOVED", P2, spell=222),
    end(),
]


def test_scan_counts_applications_keys_deaths_and_health_share_outside_bosses(tmp_path):
    stats = scan([write_log(tmp_path, LOG)])
    row = stats[(2521, 373693)]
    assert (row["applications"], row["keys"], row["deaths"]) == (3, 2, 1)
    assert sorted(row["shares"]) == [0.0, 0.0, 0.5]
    assert row["zone"] == "Ruby Life Pools" and row["name"] == "Living Bomb"
    assert (2521, 111) not in stats


def test_review_keeps_rows_with_three_applications_and_the_reacts_set_by_hand(tmp_path):
    out = tmp_path / "review.tsv"
    write_review(scan([write_log(tmp_path, LOG)]), str(out))
    lines = out.read_text(encoding="utf-8").splitlines()
    assert lines[0].split("\t") == ["instance", "zone", "spell", "name", "applications", "keys", "deaths",
                                    "median_share", "p90_share", "react"]
    assert [l.split("\t")[2] for l in lines[1:]] == ["373693"]
    out.write_text(lines[0] + "\n" + lines[1].rsplit("\t", 1)[0] + "\tDEFENSIVE\n", encoding="utf-8")
    write_review(scan([write_log(tmp_path, LOG)]), str(out))
    row = out.read_text(encoding="utf-8").splitlines()[1].split("\t")
    assert row[6] == "1" and row[7] == "0.00" and row[8] == "0.50" and row[9] == "DEFENSIVE"


def test_gen_writes_the_reviewed_reacts_and_rejects_an_unknown_one(tmp_path):
    review = tmp_path / "review.tsv"
    head = "instance\tzone\tspell\tname\tapplications\tkeys\tdeaths\tmedian_share\tp90_share\treact\n"
    review.write_text(head + "2521\tRuby Life Pools\t373693\tLiving Bomb\t19\t3\t2\t0.40\t0.90\tDEFENSIVE\n"
                      + "2521\tRuby Life Pools\t1305201\tExcavating Blast\t9\t3\t0\t0.10\t0.20\t\n", encoding="utf-8")
    out = tmp_path / "Debuffs.lua"
    gen(str(review), str(out))
    text = out.read_text(encoding="utf-8")
    assert "CastAheadDebuffs = {" in text
    assert "[2521] = {" in text and '[373693] = "DEFENSIVE",' in text
    assert "1305201" not in text
    review.write_text(head + "2521\tRuby Life Pools\t373693\tLiving Bomb\t19\t3\t2\t0.40\t0.90\tSAVE\n", encoding="utf-8")
    with pytest.raises(ValueError):
        gen(str(review), str(out))
