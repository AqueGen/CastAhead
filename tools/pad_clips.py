"""Write Sounds/en/<KEY>_d<N>.ogg: the call clip after N seconds of silence.

A debuff call rides the game's aura sound, which plays when the aura lands and stops after 5 s,
so the only way to say it later is silence at the start of the file. Needs ffmpeg on PATH.

    python tools/pad_clips.py
"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SOUNDS = os.path.join(HERE, "..", "Sounds", "en")
KEYS = ("DEFENSIVE", "TANK", "MAGIC", "POISON", "CURSE", "DISEASE")
DELAYS = (1, 2, 3)  # 4 s of silence pushes the dispel clips past the 5 s cut


def main():
    for key in KEYS:
        src = os.path.join(SOUNDS, key + ".ogg")
        for d in DELAYS:
            dst = os.path.join(SOUNDS, "%s_d%d.ogg" % (key, d))
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-af", "adelay=%d:all=1" % (d * 1000),
                            "-c:a", "libvorbis", "-q:a", "4", "-ar", "44100", dst], check=True)
            print(os.path.basename(dst))


if __name__ == "__main__":
    main()
