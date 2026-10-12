#!/usr/bin/env python3
"""Sound check of a converted run against the protected set's run of the same inputs.

    audiocheck.py REF_DIR TEST_DIR [--diverged FRAME] [--min-run N]

Both runs from harness/fullgame.sh with AUDIO=1: sound.txt (tools/lua/sndmon.lua: every
command packet the 68000 hands to the Z80, whether the Z80 read it before the next one,
the Z80 ready waits) and audio.wav (MAME -wavwrite, the mixed sound output).

Reports
  * command packets: count, sequence identical or first difference, packets the Z80 never
    read (overwritten), the longest Z80 ready wait;
  * sound output, per video frame (RMS over the frame's samples):
      - the first frame whose samples differ at all,
      - dropouts: runs of >= N frames where one set is silent and the other is not, and
        runs where one set is more than 12 dB below the other,
      - silent stretches (>= N frames) in each run, for the part after the games diverge
        (--diverged: logical games differ from there; content is compared only before).
"""
import argparse
import os
import wave

import numpy as np

FPS = 10e6 / (640 * 264)          # PGM video frame rate (59.185 Hz)
SILENT = 30.0                     # RMS (16-bit full scale 32767) below which a frame is silent


def sound_log(path):
    pk, lost, waits, summary = [], [], {}, ""
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "P":
            pk.append((int(p[1]), " ".join(p[2:])))
        elif p[0] == "LOST":
            lost.append(int(p[1]))
        elif p[0] == "F":
            waits[int(p[1])] = int(p[5])
        elif p[0] == "SUMMARY":
            summary = line.strip()
    return pk, lost, waits, summary


def frame_rms(path):
    w = wave.open(path)
    a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int32)
    if w.getnchannels() > 1:
        a = a.reshape(-1, w.getnchannels()).mean(axis=1)
    spf = w.getframerate() / FPS
    n = int(len(a) / spf)
    edges = (np.arange(n + 1) * spf).astype(np.int64)
    sq = np.concatenate(([0.0], np.cumsum(a.astype(np.float64) ** 2)))
    rms = np.sqrt((sq[edges[1:]] - sq[edges[:-1]]) / np.diff(edges))
    return a, edges, rms


def runs(mask, min_run):
    out, start = [], None
    for i, m in enumerate(list(mask) + [False]):
        if m and start is None:
            start = i
        elif not m and start is not None:
            if i - start >= min_run:
                out.append((start, i - 1))
            start = None
    return out


def fmt_runs(r, limit=12):
    s = ", ".join("%d-%d" % x if x[0] != x[1] else "%d" % x[0] for x in r[:limit])
    return s + (" ..." if len(r) > limit else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("test")
    ap.add_argument("--diverged", type=int, help="video frame from which the games differ")
    ap.add_argument("--min-run", type=int, default=3)
    a = ap.parse_args()

    # command packets
    rp, rl, rw, rs = sound_log(os.path.join(a.ref, "sound.txt"))
    tp, tl, tw, ts = sound_log(os.path.join(a.test, "sound.txt"))
    print("sound commands (packets to the Z80):")
    print("  ref : %s" % rs)
    print("  test: %s" % ts)
    n = min(len(rp), len(tp))
    first = next((i for i in range(n) if rp[i][1] != tp[i][1]), None)
    if first is None and len(rp) == len(tp):
        print("  packet sequence identical (%d packets)" % len(rp))
    else:
        i = first if first is not None else n
        print("  packet sequences: %d / %d, identical up to packet %d (ref frame %s, test frame %s)" % (
            len(rp), len(tp), i, rp[i][0] if i < len(rp) else "-", tp[i][0] if i < len(tp) else "-"))
    same_frame = sum(1 for i in range(n) if rp[i] == tp[i])
    print("  packets in the same video frame with the same content: %d of %d" % (same_frame, n))
    for name, lost in (("ref", rl), ("test", tl)):
        print("  %-4s packets not read by the Z80 before the next one: %d %s" % (
            name, len(lost), ("(frames %s)" % ", ".join(map(str, lost[:10]))) if lost else ""))
    big = sorted(((w, f) for f, w in tw.items() if w > 50000), reverse=True)[:8]
    print("  test: longest Z80 ready waits (cycles @ frame): %s" % ", ".join("%d @ %d" % x for x in big))
    big = sorted(((w, f) for f, w in rw.items() if w > 50000), reverse=True)[:8]
    print("  ref : longest Z80 ready waits (cycles @ frame): %s" % ", ".join("%d @ %d" % x for x in big))

    # sound output
    ra, re_, rr = frame_rms(os.path.join(a.ref, "audio.wav"))
    ta, te, tr = frame_rms(os.path.join(a.test, "audio.wav"))
    n = min(len(rr), len(tr))
    rr, tr = rr[:n], tr[:n]
    m = min(len(ra), len(ta))
    d = np.nonzero(ra[:m] != ta[:m])[0]
    first_diff = int(np.searchsorted(re_, d[0], side="right") - 1) if len(d) else None
    print("sound output: %d video frames (%.0f s)" % (n, n / FPS))
    print("  samples identical %s" % ("in every frame" if first_diff is None else
                                       "up to video frame %d" % (first_diff - 1)))
    cmp_end = a.diverged if a.diverged else n
    rs_, ts_ = rr < SILENT, tr < SILENT
    drop_t = runs(ts_[:cmp_end] & ~rs_[:cmp_end], a.min_run)
    drop_r = runs(rs_[:cmp_end] & ~ts_[:cmp_end], a.min_run)
    loud = (rr[:cmp_end] > 300) | (tr[:cmp_end] > 300)
    with np.errstate(divide="ignore", invalid="ignore"):
        db = 20 * np.log10(np.maximum(tr[:cmp_end], 1) / np.maximum(rr[:cmp_end], 1))
    low_t = runs(loud & (db < -12), a.min_run)
    low_r = runs(loud & (db > 12), a.min_run)
    act = loud
    print("  compared frames 0-%d%s:" % (cmp_end - 1, " (the games diverge at %d)" % a.diverged if a.diverged else ""))
    print("    level difference test - ref per frame (dB, frames with sound): median %.2f, 1%% %.2f, 99%% %.2f" % (
        np.median(db[act]), np.percentile(db[act], 1), np.percentile(db[act], 99)))
    print("    test silent where ref is not (runs >= %d frames): %d %s" % (a.min_run, len(drop_t), fmt_runs(drop_t)))
    print("    ref silent where test is not (runs >= %d frames): %d %s" % (a.min_run, len(drop_r), fmt_runs(drop_r)))
    print("    test > 12 dB below ref (runs >= %d frames): %d %s" % (a.min_run, len(low_t), fmt_runs(low_t)))
    print("    ref > 12 dB below test (runs >= %d frames): %d %s" % (a.min_run, len(low_r), fmt_runs(low_r)))
    for name, s in (("ref", rs_), ("test", ts_)):
        r = runs(s, a.min_run)
        tot = sum(y - x + 1 for x, y in r)
        print("  %-4s silent stretches (>= %d frames): %d, %d frames in all: %s" % (name, a.min_run, len(r), tot, fmt_runs(r, 20)))


if __name__ == "__main__":
    main()
