"""Render CastAhead's spoken calls into Sounds/<lang>/<KEY>.ogg with Azure TTS.

The game can speak for us (C_CombatAudioAlert), but only when the player has
that option on; shipping our own clips makes the call audible for everyone and
keeps the voice consistent. One clip per advice category plus a "soon" variant
for the lead warning. Keys must match CastAheadMatch.ADVICE (test.lua checks the
files exist).

Credentials come from the user environment by name - AZURE_SPEECH_KEY and
AZURE_SPEECH_REGION - and are never printed. Needs ffmpeg on PATH: Azure has no
Vorbis output and WoW plays no Opus, so the WAV is converted here.

    python tools/voice.py            # render everything missing
    python tools/voice.py --force    # re-render all
"""
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

LANG = "en"
VOICE = "en-US-GuyNeural"
XML_LANG = "en-US"

# CastAheadMatch.ADVICE key -> what is said. The "soon" form is the 3s heads-up before a predicted
# cast; the plain form fires when the cast actually starts.
LINES = {
    "KICK": "interrupt",
    "CC": "stun",
    "TANK": "tank buster",
    "AOE": "AOE damage",
    "DODGE": "dodge",
    "FRONTAL": "frontal",
    "TARGET": "targeted",
    "DISPEL": "dispel",
    "POISON": "dispel poison",
    "CURSE": "dispel curse",
    "MAGIC": "dispel magic",
    "SOOTHE": "soothe enrage",
    "PURGE": "purge buff",
    "DISEASE": "dispel disease",
    "BLEED": "bleed, defensive",
    "SWITCH": "switch target",
    "ALERT": "danger",
}

# Trim the neural voice's padding (about 0.2 s in front, 0.9 s behind): the
# front is a late warning, the back is nothing at all.
TRIM = ("silenceremove=start_periods=1:start_silence=0.02:start_threshold=-45dB:detection=peak,"
        "areverse,"
        "silenceremove=start_periods=1:start_silence=0.10:start_threshold=-45dB:detection=peak,"
        "areverse")

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Sounds", LANG)


def env(name):
    """User-scope value first: a setx is invisible to an already-running shell."""
    value = None
    if sys.platform == "win32":
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 '[Environment]::GetEnvironmentVariable("%s","User")' % name],
                capture_output=True, text=True, timeout=30)
            value = out.stdout.strip() or None
        except (OSError, subprocess.SubprocessError):
            value = None
    value = value or os.environ.get(name)
    if not value:
        raise SystemExit("%s is not set" % name)
    return value


def filename(key, soon):
    return key.replace(" ", "_") + ("_soon" if soon else "") + ".ogg"


def synth(text, dest_wav, key, region):
    ssml = ('<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
            'xml:lang="%s"><voice name="%s">%s</voice></speak>' % (XML_LANG, VOICE, text))
    req = urllib.request.Request(
        "https://%s.tts.speech.microsoft.com/cognitiveservices/v1" % region,
        data=ssml.encode("utf-8"),
        headers={
            "Ocp-Apim-Subscription-Key": key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "riff-48khz-16bit-mono-pcm",
            "User-Agent": "castahead-voice",
        })
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                open(dest_wav, "wb").write(r.read())
            return True
        except urllib.error.HTTPError as e:
            if e.code in (429, 503):
                time.sleep(10 * (attempt + 1))
                continue
            print("FAIL %s: HTTP %d" % (os.path.basename(dest_wav), e.code))
            return False
        except Exception as e:  # network hiccup: retry
            print("RETRY %s: %s" % (os.path.basename(dest_wav), e))
            time.sleep(5)
    return False


def to_ogg(wav, ogg):
    r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-af", TRIM,
                        "-c:a", "libvorbis", "-q:a", "4", "-ar", "44100", ogg])
    return r.returncode == 0


def main(force=False):
    key, region = env("AZURE_SPEECH_KEY"), env("AZURE_SPEECH_REGION")
    os.makedirs(OUT, exist_ok=True)
    done = skipped = failed = 0
    for k, text in LINES.items():
        for soon in (False, True):
            ogg = os.path.join(OUT, filename(k, soon))
            if os.path.exists(ogg) and not force:
                skipped += 1
                continue
            wav = ogg[:-4] + ".wav"
            line = text + " soon" if soon else text
            if synth(line, wav, key, region) and to_ogg(wav, ogg):
                done += 1
            else:
                failed += 1
            if os.path.exists(wav):
                os.remove(wav)
    print("%d rendered, %d kept, %d failed -> %s" % (done, skipped, failed, os.path.normpath(OUT)))
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if main("--force" in sys.argv[1:]) else 1)
