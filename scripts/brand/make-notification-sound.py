#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Synthesise ChatLoom's message notification sound.

An original, short, soft two-note "blip": a rising pair of sine tones
(A5 -> E6, a perfect fifth) with a quick pitch lift at each onset (the "pop"
of a bubble), a gentle 3 ms attack, exponential decay and a quiet second
harmonic. About 210 ms, mono, 48 kHz, normalised to about -16 LUFS
(ITU-R BS.1770 K-weighting, measured over the whole clip because it is
shorter than one 400 ms block) and kept well below clipping.

Output: Ogg Vorbis via ffmpeg (libvorbis) when available, WAV otherwise.
Android plays both from `res/raw/`; the channel refers to the resource by
name (`chatloom_message`), so the extension does not matter to the app.

    python3 scripts/brand/make-notification-sound.py \
        --out android/app/src/main/res/raw/chatloom_message.ogg \
        --png /tmp/chatloom_message.png

Needs numpy; matplotlib only for --png.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

RATE = 48_000
TARGET_LUFS = -16.0
PEAK_CEILING_DBFS = -1.0

# (start s, frequency Hz, length s, gain)
NOTES = (
    (0.000, 880.00, 0.120, 0.85),  # A5
    (0.075, 1318.51, 0.135, 1.00),  # E6
)


def _note(freq: float, length: float, gain: float) -> np.ndarray:
    n = int(round(length * RATE))
    t = np.arange(n) / RATE
    # Pitch starts 6 % low and rises to the note within ~25 ms: a soft pop.
    lift = 1.0 - 0.06 * np.exp(-t / 0.008)
    phase = 2 * np.pi * np.cumsum(freq * lift) / RATE
    tone = np.sin(phase) + 0.18 * np.sin(2 * phase) + 0.04 * np.sin(3 * phase)
    attack = np.clip(t / 0.003, 0.0, 1.0)
    attack = 0.5 - 0.5 * np.cos(np.pi * attack)  # raised-cosine, no click
    decay = np.exp(-t / 0.038)
    env = attack * decay
    tail = np.ones(n)
    fade = int(0.015 * RATE)
    tail[-fade:] = 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, fade))
    return gain * tone * env * tail


def synthesize() -> np.ndarray:
    end = max(start + length for start, _, length, _ in NOTES)
    out = np.zeros(int(round(end * RATE)) + 1)
    for start, freq, length, gain in NOTES:
        note = _note(freq, length, gain)
        i = int(round(start * RATE))
        out[i : i + len(note)] += note
    return out


def _biquad(x: np.ndarray, b, a) -> np.ndarray:
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    b0, b1, b2 = b
    _, a1, a2 = a
    for i, xi in enumerate(x):
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xi, y1, yi
        y[i] = yi
    return y


def loudness_lufs(x: np.ndarray) -> float:
    """BS.1770 loudness of a mono 48 kHz clip measured over its length."""
    k = _biquad(
        x,
        (1.53512485958697, -2.69169618940638, 1.19839281085285),
        (1.0, -1.69065929318241, 0.73248077421585),
    )
    k = _biquad(k, (1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621))
    return -0.691 + 10 * np.log10(np.mean(k**2) + 1e-20)


def normalise(x: np.ndarray) -> np.ndarray:
    x = x * 10 ** ((TARGET_LUFS - loudness_lufs(x)) / 20)
    ceiling = 10 ** (PEAK_CEILING_DBFS / 20)
    peak = np.max(np.abs(x))
    if peak > ceiling:
        x = x * ceiling / peak
    return x


def write_wav(path: Path, x: np.ndarray) -> None:
    pcm = np.round(np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def read_back(path: Path) -> np.ndarray:
    """Decode the written file (through ffmpeg for Ogg) to float samples."""
    if path.suffix == ".wav":
        with wave.open(str(path)) as w:
            return np.frombuffer(w.readframes(w.getnframes()), "<i2") / 32768
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1",
         "-ar", str(RATE), "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, "<i2") / 32768


def report(label: str, x: np.ndarray) -> None:
    peak = np.max(np.abs(x))
    rms = np.sqrt(np.mean(x**2))
    clipped = int(np.sum(np.abs(x) >= 32767 / 32768))
    print(
        f"{label}: {len(x) / RATE * 1000:.0f} ms, "
        f"peak {20 * np.log10(peak):.1f} dBFS, "
        f"RMS {20 * np.log10(rms):.1f} dBFS, "
        f"loudness {loudness_lufs(x):.1f} LUFS, clipped samples {clipped}"
    )


def plot(path: Path, x: np.ndarray) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, (wave_ax, spec_ax) = plt.subplots(2, 1, figsize=(9, 6))
    t = np.arange(len(x)) / RATE * 1000
    wave_ax.plot(t, x, linewidth=0.6)
    wave_ax.set(title="chatloom_message: waveform", xlabel="ms", ylabel="amplitude")
    wave_ax.set_ylim(-1, 1)
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1 / RATE)
    spec_ax.semilogx(freqs[1:], 20 * np.log10(spec[1:] / spec.max() + 1e-9))
    spec_ax.set(title="spectrum", xlabel="Hz", ylabel="dB")
    spec_ax.set_xlim(100, 20_000)
    spec_ax.set_ylim(-90, 3)
    fig.tight_layout()
    fig.savefig(path, dpi=110)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True,
                        help="output .ogg (needs ffmpeg) or .wav")
    parser.add_argument("--png", type=Path, help="waveform/spectrum image")
    args = parser.parse_args()

    sound = normalise(synthesize())
    report("synthesised", sound)
    out: Path = args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.suffix == ".ogg" and shutil.which("ffmpeg") is None:
        out = out.with_suffix(".wav")
        print("ffmpeg not found: writing WAV instead", file=sys.stderr)
    if out.suffix == ".ogg":
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "sound.wav"
            write_wav(wav, sound)
            subprocess.run(
                ["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a",
                 "libvorbis", "-q:a", "6", "-ac", "1",
                 # No metadata: the file stays reproducible and anonymous.
                 "-map_metadata", "-1", "-fflags", "+bitexact",
                 "-flags:a", "+bitexact", str(out)],
                check=True,
            )
    else:
        write_wav(out, sound)
    decoded = read_back(out)
    report(f"{out.name} ({out.stat().st_size} bytes)", decoded)
    if args.png:
        plot(args.png, decoded)
        print(f"plot: {args.png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
