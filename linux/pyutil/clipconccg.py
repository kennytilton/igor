#!/usr/bin/env python3
"""
clipconc: fast MP4 concat with cross-fades via ffmpeg xfade (Pop!_OS-friendly)

Spec highlights implemented:
- Positional args: alternating file names and integers (seconds)
  - leading int = fade-in on first clip
  - trailing int = fade-out on last clip
  - internal int = cross-fade duration between adjacent clips
  - missing internal int between two clips defaults to 1
- Normalization: 1280x720 (scale+pad), DAR 16:9, CFR 30fps, yuv420p
- Video transitions: xfade=transition=fade
- Default: audio stripped (-an)
- Optional: --audio attempts to preserve audio; inserts silence if a clip has no audio
- Output name: underscore-join of original args, stripping .mp4 from clip tokens; overwrite -y
- Prints absolute output path on success
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple, Union, Optional


INT_RE = re.compile(r"^-?\d+$")


@dataclass(frozen=True)
class Clip:
    path: Path
    duration: float
    has_audio: bool


def is_int_token(s: str) -> bool:
    return bool(INT_RE.match(s))


def die(msg: str, code: int = 2) -> None:
    print(f"clipconc: {msg}", file=sys.stderr)
    sys.exit(code)


def run_cmd(cmd: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def ffprobe_duration_seconds(p: Path) -> float:
    # Prefer container duration; fallback is not attempted (keeps behavior strict/predictable).
    cmd = [
        "ffprobe",
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(p),
    ]
    r = run_cmd(cmd)
    if r.returncode != 0:
        die(f"ffprobe failed for {p}:\n{r.stderr.strip()}")
    try:
        dur = float(r.stdout.strip())
    except ValueError:
        die(f"could not parse duration from ffprobe for {p}: {r.stdout!r}")
    if dur <= 0:
        die(f"non-positive duration reported for {p}: {dur}")
    return dur


def ffprobe_has_audio(p: Path) -> bool:
    cmd = [
        "ffprobe",
        "-v", "error",
        "-select_streams", "a",
        "-show_entries", "stream=index",
        "-of", "csv=p=0",
        str(p),
    ]
    r = run_cmd(cmd)
    if r.returncode != 0:
        die(f"ffprobe failed (audio probe) for {p}:\n{r.stderr.strip()}")
    return bool(r.stdout.strip())


def normalize_clip_token(tok: str) -> str:
    # If missing .mp4, append; do not otherwise alter path text.
    if tok.lower().endswith(".mp4"):
        return tok
    return tok + ".mp4"


def parse_args_sequence(raw_tokens: List[str]) -> Tuple[List[Union[int, str]], int, int, List[int], List[str]]:
    """
    Returns:
      canonical_tokens: list of ints and clip-string tokens (with .mp4 appended if absent)
      fade_in: seconds (>=0)
      fade_out: seconds (>=0)
      transitions: list of length (num_clips-1), each >=0
      original_tokens_for_naming: original tokens but with clip extensions stripped later
    """
    if not raw_tokens:
        die("no arguments. See --help.", 2)

    # Keep originals for filename generation exactly as provided (except we strip .mp4 later for clip tokens).
    original_tokens_for_naming = raw_tokens[:]

    # Convert to typed tokens, but preserve clip tokens as strings (we append .mp4 if needed).
    typed: List[Union[int, str]] = []
    for t in raw_tokens:
        if is_int_token(t):
            v = int(t)
            if v < 0:
                die(f"negative duration not allowed: {t}")
            typed.append(v)
        else:
            typed.append(normalize_clip_token(t))

    # Identify leading/trailing integers for fades.
    fade_in = 0
    fade_out = 0
    start = 0
    end = len(typed)

    if isinstance(typed[0], int):
        fade_in = typed[0]
        start = 1
    if end - start >= 1 and isinstance(typed[-1], int):
        fade_out = typed[-1]
        end -= 1

    core = typed[start:end]
    if not core:
        die("no clip files provided (only fades?).")

    # Core must contain at least one string.
    if not any(isinstance(x, str) for x in core):
        die("no clip files provided.")

    # Parse core into (clip, transition, clip, transition, ...), injecting default transition=1 for adjacent clips.
    clips: List[str] = []
    transitions: List[int] = []

    i = 0
    while i < len(core):
        x = core[i]
        if not isinstance(x, str):
            die(f"unexpected integer where a clip was required: {x}")
        clips.append(x)
        i += 1
        if i >= len(core):
            break
        y = core[i]
        if isinstance(y, int):
            transitions.append(y)
            i += 1
            if i >= len(core):
                die("dangling transition at end (missing final clip).")
            z = core[i]
            if not isinstance(z, str):
                die("transition must be between two clips.")
            # loop continues; next iteration will consume z as clip
        else:
            # adjacent clip: implied transition 1
            transitions.append(1)
            # do not advance i; next loop consumes this as next clip

    if len(clips) == 1:
        transitions = []

    # Build canonical tokens list preserving the *typed* interpretation:
    # [fade_in?] clip0 [t0] clip1 [t1] ... clipN [fade_out?]
    canonical: List[Union[int, str]] = []
    if fade_in:
        canonical.append(fade_in)
    canonical.append(clips[0])
    for idx in range(len(transitions)):
        canonical.append(transitions[idx])
        canonical.append(clips[idx + 1])
    if fade_out:
        canonical.append(fade_out)

    return canonical, fade_in, fade_out, transitions, clips, original_tokens_for_naming


def output_filename_from_original_tokens(original_tokens: List[str]) -> str:
    parts: List[str] = []
    for t in original_tokens:
        if is_int_token(t):
            parts.append(t)
        else:
            # Strip only a trailing ".mp4" (case-insensitive) from the original token.
            if t.lower().endswith(".mp4"):
                parts.append(t[:-4])
            else:
                parts.append(t)
    return "_".join(parts) + ".mp4"


def build_ffmpeg_filtergraph(
    clips: List[Clip],
    fade_in: int,
    fade_out: int,
    transitions: List[int],
    include_audio: bool,
) -> Tuple[str, str, Optional[str]]:
    """
    Returns (filter_complex, vmap_label, amap_label_or_None)
    """
    n = len(clips)
    if n == 0:
        die("internal error: no clips")

    # Video normalization per input: scale+pad, setdar, fps, format.
    # Apply fade-in to first, fade-out to last.
    vlabels: List[str] = []
    alabels: List[str] = []

    for i, c in enumerate(clips):
        v_in = f"[{i}:v]"
        v_out = f"[v{i}]"

        v_chain = (
            f"{v_in}"
            f"scale=1280:720:force_original_aspect_ratio=decrease,"
            f"pad=1280:720:(ow-iw)/2:(oh-ih)/2,"
            f"setdar=16/9,"
            f"fps=30,"
            f"format=yuv420p"
        )

        if i == 0 and fade_in > 0:
            v_chain += f",fade=t=in:st=0:d={fade_in}"
        if i == n - 1 and fade_out > 0:
            # fade-out start time = duration - fade_out
            st = max(0.0, clips[i].duration - float(fade_out))
            v_chain += f",fade=t=out:st={st:.6f}:d={fade_out}"

        v_chain += f"{v_out}"
        vlabels.append(v_out)

        if include_audio:
            # Provide [a{i}] for each clip; if missing audio, inject silence for clip duration.
            if c.has_audio:
                # normalize to stereo 48k for stability
                a_chain = f"[{i}:a]aformat=sample_rates=48000:channel_layouts=stereo,aresample=48000[a{i}]"
            else:
                # anullsrc generates infinite; trim to duration
                a_chain = (
                    f"anullsrc=channel_layout=stereo:sample_rate=48000,"
                    f"atrim=0:{c.duration:.6f},asetpts=PTS-STARTPTS[a{i}]"
                )
            alabels.append(f"[a{i}]")
        # else: no audio labels

    filters: List[str] = []
    filters.extend([s for s in vlabels])  # placeholder, replaced below

    # Actually store full per-input filter strings
    per_input_filters: List[str] = []
    for i, c in enumerate(clips):
        v_in = f"[{i}:v]"
        v_out = f"[v{i}]"
        v_chain = (
            f"{v_in}"
            f"scale=1280:720:force_original_aspect_ratio=decrease,"
            f"pad=1280:720:(ow-iw)/2:(oh-ih)/2,"
            f"setdar=16/9,"
            f"fps=30,"
            f"format=yuv420p"
        )
        if i == 0 and fade_in > 0:
            v_chain += f",fade=t=in:st=0:d={fade_in}"
        if i == n - 1 and fade_out > 0:
            st = max(0.0, clips[i].duration - float(fade_out))
            v_chain += f",fade=t=out:st={st:.6f}:d={fade_out}"
        v_chain += f"{v_out}"
        per_input_filters.append(v_chain)

        if include_audio:
            if c.has_audio:
                per_input_filters.append(
                    f"[{i}:a]aformat=sample_rates=48000:channel_layouts=stereo,aresample=48000[a{i}]"
                )
            else:
                per_input_filters.append(
                    f"anullsrc=channel_layout=stereo:sample_rate=48000,"
                    f"atrim=0:{c.duration:.6f},asetpts=PTS-STARTPTS[a{i}]"
                )

    # Build xfade chain.
    if n == 1:
        v_final = "[v0]"
        a_final = "[a0]" if include_audio else None
        return ";".join(per_input_filters), v_final, a_final

    prev_v = "[v0]"
    prev_a = "[a0]" if include_audio else None

    prev_out_dur = clips[0].duration

    for i in range(1, n):
        t = transitions[i - 1]
        if t < 0:
            die("negative transition not allowed")
        # Transition duration cannot exceed either clip duration (ffmpeg will error).
        # Keep spec strict; fail early with a clear message.
        if t > clips[i - 1].duration or t > clips[i].duration:
            die(
                f"transition {t}s between clip {i-1} and {i} exceeds one of the clip durations "
                f"({clips[i-1].duration:.3f}s, {clips[i].duration:.3f}s)"
            )

        offset = max(0.0, prev_out_dur - float(t))
        out_v = f"[vx{i}]"
        per_input_filters.append(
            f"{prev_v}[v{i}]xfade=transition=fade:duration={t}:offset={offset:.6f}{out_v}"
        )
        prev_v = out_v

        if include_audio and prev_a is not None:
            out_a = f"[ax{i}]"
            # acrossfade crossfades end of first with start of second over duration t
            per_input_filters.append(
                f"{prev_a}[a{i}]acrossfade=d={t}:c1=tri:c2=tri{out_a}"
            )
            prev_a = out_a

        prev_out_dur = prev_out_dur + clips[i].duration - float(t)

    v_final = prev_v
    a_final = prev_a if include_audio else None
    return ";".join(per_input_filters), v_final, a_final


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="clipconc",
        add_help=True,
        formatter_class=argparse.RawTextHelpFormatter,
        description="Concatenate MP4 clips with cross-fades (xfade), with normalization to 1280x720 @ 30fps.",
        epilog=(
            "Examples:\n"
            "  clipconc intro scene1 5 outro\n"
            "  clipconc 2 intro scene1 5 outro 2\n"
            "  clipconc --audio 1 a b 2 c 1\n"
        ),
    )
    ap.add_argument(
        "--audio",
        action="store_true",
        help="Preserve audio (inserts silence for clips that lack audio). Default strips audio (-an).",
    )
    ap.add_argument(
        "tokens",
        nargs="*",
        help="Sequence of clip names and integer durations. Clips may omit .mp4.",
    )

    ns = ap.parse_args(argv)

    if not ns.tokens:
        ap.print_usage(sys.stderr)
        return 2

    canonical, fade_in, fade_out, transitions, clip_tokens, original_tokens_for_naming = parse_args_sequence(ns.tokens)

    # Resolve clip paths and validate existence
    clip_paths: List[Path] = []
    for ct in clip_tokens:
        p = Path(ct)
        if not p.exists():
            die(f"missing file: {ct}")
        clip_paths.append(p)

    # Probe clip durations (needed for fade-out start and xfade offsets)
    clips: List[Clip] = []
    for p in clip_paths:
        dur = ffprobe_duration_seconds(p)
        has_a = ffprobe_has_audio(p) if ns.audio else False
        clips.append(Clip(path=p, duration=dur, has_audio=has_a))

    out_name = output_filename_from_original_tokens(original_tokens_for_naming)
    out_path = (Path.cwd() / out_name).resolve()

    filter_complex, vmap, amap = build_ffmpeg_filtergraph(
        clips=clips,
        fade_in=fade_in,
        fade_out=fade_out,
        transitions=transitions,
        include_audio=ns.audio,
    )

    cmd: List[str] = ["ffmpeg", "-y"]
    for c in clips:
        cmd += ["-i", str(c.path)]

    cmd += ["-filter_complex", filter_complex, "-map", vmap]

    if ns.audio and amap is not None:
        cmd += ["-map", amap]
    else:
        cmd += ["-an"]

    cmd += [
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        str(out_path),
    ]

    r = subprocess.run(cmd)
    if r.returncode != 0:
        die("ffmpeg failed (see output above).", r.returncode)

    print(str(out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))