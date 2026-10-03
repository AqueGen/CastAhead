# Key recorder and wrong-call reports

Status: design approved in chat on 2026-10-03, awaiting review of this written spec.

## Goal

A player turns one switch on, plays keys as usual, and we get trustworthy material to judge the addon by: what the game did, what the addon predicted and said, and the moments the player saw it go wrong. The same mechanism serves two audiences:

- the owner, who also has the combat log and wants a full audit of timings and calls after each key;
- other players, who have no combat log to share, mark wrong calls in play and send a report through a GitHub issue or a CurseForge comment.

The deciding requirement for the report format: the owner must be able to reconstruct exactly what happened, when, where and how. Human readability is a bonus, not the goal.

## What already exists and stays

- Development mode with "Combat log in dungeons" (auto `/combatlog` plus `advancedCombatLogging`).
- The nameplate probe (`/ca probe`): per cast start it samples what the unit API returns, keeps player-cast anchors for clock alignment, and since #41 the spell and call made at the start. It stays the tool for API research; the recorder does not depend on it and does not switch it on.
- `CastAheadTools/fingerprint_join.py` and the replay harness.

## Two levels, one mechanism

| Switch | Where | Turns on |
|---|---|---|
| Report wrong calls | General tab, Advanced group, off by default | key journal, mark key binding, on-screen mark button, post-key chat line, `/ca report` |
| Development mode + Combat log in dungeons | existing | all of the above plus the combat log, so the owner's audit can join the journal to the log |

The public switch never touches the combat log, so other players do not end up with hundreds of MB of logs.

## Components

### Recorder.lua (new file, listed in the TOC after Core.lua)

Owns the journal. Core does not write journal entries itself; it calls a small set of Recorder functions at the points listed below, so Core.lua does not grow and the recorder can be tested on its own. A new TOC entry needs a client restart the first time; Core must keep working when `CastAheadRecorder` is nil (same guard pattern as `CastAheadTimeline`).

Storage: `CastAheadDB.journal = { keys = { <key>, ... } }`, newest last, at most 5 keys. Each key holds a header and an array of event lines. A per-key line cap (start at 20000) stops runaway growth; when it is hit the key is flagged `truncated = <time>` and the report says so. Nothing is dropped silently.

Key header: format version, addon version, data checksum, instance id and name, keystone level, affix ids if readable, start time, end time, completed or abandoned, player spec role. No player, realm, guild or party names.

Data checksum: computed once at load over `CastAheadData`, `CastAheadPriority` and `CastAheadTraits` (a stable string hash of the serialized rows), so the audit reads the exact data the player ran.

Outside a keystone the recorder still runs inside any dungeon or open-world combat, as a pseudo-key with level 0, so marks work everywhere.

### Event lines

One line per event, `t|type|slot|fields`, `t` in milliseconds since key start (from the addon's own clock, `GetTime()`), `slot` the nameplate slot number so one mob's events link up. Spell and creature ids, never names. Types:

- `KEY` start / end (also written into the header)
- `PULL` boundary: player entered or left combat
- `PLATE` added / removed (removed with reason: died, gone, reset), with level, power type, classification
- `ENGAGE` the moment the addon saw the plate enter combat (this is what `first` is measured from)
- `LOCK` the creature the plate was resolved to, and how (cast, traits, neighbour)
- `START` cast or channel start: claimed spell, call key, candidate ids, target shown yes/no, interruptible if known
- `STOP` / `KICK` / `FAIL`: measured cast length in ms, final candidate ids after each narrowing step (step name and survivors), call
- `PRED` a prediction set or moved: spell, due time, approximate yes/no, source (repeat, projected, opening)
- `TL` timeline event added / finished / cancelled with reason
- `HEADS` heads-up voiced (when the lead warning is on)
- `MARK` player mark: mark number, optional note, snapshot (see below), screenshot taken yes/no
- `TRIM` cap reached

Recording only appends plain numbers and strings the addon already holds as ordinary Lua values. It never reads, compares or boolean-tests a value that 12.x may return Secret.

### Mark

- Key binding "Cast Ahead: mark a wrong call" via `Bindings.xml` (loaded by the client automatically from the addon root, shown under the addon's own header in the game's key bindings).
- A small movable on-screen button for players who do not bind keys, shown only while the switch is on and the player is in combat or in a dungeon.
- On mark: writes a `MARK` line with a snapshot of every tracked plate within the last 10 seconds (casting state, last claim and call, candidates, live predictions with due times), prints one confirmation line in chat, and takes a screenshot with `Screenshot()` if that call works from an addon in combat. That is verified in game first with a throwaway probe; if it does not work, marks carry no screenshot and the option is not offered.

### After the key

- One chat line at key end: casts seen, calls made, marks, and a hint to `/ca report`.
- `/ca report` opens a window: a dropdown of the stored keys (newest selected), an edit box per mark for an optional "what really happened" note, and a read-only, pre-selected text box with the export for Ctrl+C.

### Export text

Line based, same `t|type|slot|fields` lines as the journal, wrapped in a header and footer:

```
CastAhead-Report 1 addon=0.14.0 data=<checksum> instance=2923 level=12 affixes=... role=HEALER start=... len=...
# mark 1 at 05:12.4, pull 3: claimed Devour/SWITCH while casting 2.0s; note: tank buster was called swap
<every event line of the pull that contains each mark, in order>
CastAhead-Report end lines=<n>
```

- The `#` lines are the human summary, one per mark; everything else is machine data.
- It carries the whole pull around each mark, not just the marked mob, so the pull can be replayed.
- The footer line count lets the parser detect a truncated paste.
- Size: a busy pull is a few hundred lines; GitHub issue bodies hold 65536 characters. When a report would exceed about 60000 characters the window offers one pull at a time.

### GitHub issue form

`.github/ISSUE_TEMPLATE/wrong-call.yml`: required field for the export text, optional "what really happened", optional key level and dungeon if no export is available. CurseForge has no form; the README and the in-game window tell players to paste the same text into a comment or open the issue.

### tools/audit.py (repo, packager-ignored with the rest of tools/)

Two inputs, one report:

1. Owner audit: SavedVariables journal plus the combat log. Clock alignment uses the player's own casts in both (the method `fingerprint_join.py` already uses: player cast anchors recorded in the journal on `UNIT_SPELLCAST_SUCCEEDED` for the player). For every cast: real spell from the log vs claimed spell and call; for every prediction: error in seconds against the real start; for every plate: addon `ENGAGE` vs first damage taken in the log, so `first` can be checked. Marks first, each with what was on screen and what really happened.
2. Issue text without a log: parse the export, load `Data.lua` at the matching checksum (from git history by version tag), re-run the candidate narrowing offline for each marked cast from the recorded measured length, level and history, and report whether the true spell (from the player's note, or each candidate in turn) was among the candidates and which step dropped it.

Output: Markdown in `F:\claude-data\castahead-audit\<date>-<instance>.md` for the owner audit, Markdown to stdout for an issue (ready to paste as a reply).

## Error handling and limits

- Recorder disabled or file missing: Core runs unchanged.
- `/reload` mid-key: the journal is saved and the same key continues (matched by instance and start time) instead of starting a new one.
- Line cap and key cap as above; truncation is always reported.
- Export parse: unknown format version or missing footer is reported as such, never guessed around.
- No names of people anywhere in the journal or export.

## Testing

- `test_core.lua`: the journal receives the expected event lines over a scripted pull; a mark snapshots the right plates; export text round-trips through `tools/audit.py` (written to a temp file, parsed back, every line accounted for); line and key caps with the truncation flag; a reload mid-key continues the key; nothing errors when `CastAheadRecorder` is nil.
- `tools/test_audit.py` (pytest): parsing, checksum handling, truncated paste detection, offline narrowing on a fixture.
- End to end on a real log: the three Voidscar Arena keys of 2026-10-03 must surface the Brutalize/Devour start claim if it is replayed with v0.12.0 data.
- CPU: replay a full key through the harness with the recorder on and off; the difference must be negligible before release.

## Out of scope

- Uploading anything from the game (impossible for an addon) or reading the combat log in game.
- Changing what the addon calls out. The recorder only observes.
- Automatic sync of new logs; that stays the `castahead-sync` skill.

## Packaging

- Add `docs` to the `.pkgmeta` ignore list so specs do not ship.
- `Recorder.lua` and `Bindings.xml` ship.
