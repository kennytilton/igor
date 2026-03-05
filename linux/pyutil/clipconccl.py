#!/usr/bin/env python3
"""
clipconc - Concatenate MP4 clips with cross-fades and volume-independent normalization.

Usage:
    clipconc [FADE_IN] clip1 [TRANS] clip2 [TRANS] ... clipN [FADE_OUT] [--audio]

Arguments:
    FADE_IN   (optional int as first arg)  : fade-in duration in seconds for first clip
    clip      (string)                     : path to MP4 file (.mp4 auto-appended if missing)
    TRANS     (optional int between clips) : cross-fade duration in seconds (default: 1)
    FADE_OUT  (optional int as last arg)   : fade-out duration in seconds for last clip
    --audio                                : preserve audio streams (default: strip audio)

Examples:
    clipconc intro main outro
    clipconc 2 intro 3 main 2 outro 2
    clipconc intro main --audio
"""

import sys
import os
import json
import subprocess
import tempfile


def die(msg):
    print(f"clipconc error: {msg}", file=sys.stderr)
    sys.exit(1)


def ffprobe_duration(path: str) -> float:
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_streams", path
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        die(f"ffprobe failed on {path!r}: {e.stderr}")
    info = json.loads(result.stdout)
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video":
            dur = stream.get("duration")
            if dur:
                return float(dur)
    die(f"No video stream found in {path!r}")


def normalize_clip(src: str, dst: str, keep_audio: bool) -> None:
    vf = (
        "scale=1280:720:force_original_aspect_ratio=decrease,"
        "pad=1280:720:(ow-iw)/2:(oh-ih)/2,"
        "fps=30,"
        "format=yuv420p"
    )
    cmd = [
        "ffmpeg", "-y", "-i", src,
        "-vf", vf,
        "-c:v", "libx264", "-preset", "ultrafast",
    ]
    if keep_audio:
        cmd += [
            "-af", "aresample=48000,loudnorm=I=-23:TP=-2:LRA=11",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        ]
    else:
        cmd += ["-an"]
    cmd.append(dst)

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"ffmpeg normalization failed for {src!r}:\n{result.stderr}")


def parse_tokens(raw_args: list) -> tuple:
    keep_audio = False
    filtered = []
    for t in raw_args:
        if t == "--audio":
            keep_audio = True
        else:
            filtered.append(t)

    tokens = []
    for t in filtered:
        try:
            tokens.append(int(t))
        except ValueError:
            path = t if t.lower().endswith(".mp4") else t + ".mp4"
            tokens.append(path)

    return tokens, keep_audio


def build_output_name(tokens: list) -> str:
    parts = []
    for t in tokens:
        if isinstance(t, int):
            parts.append(str(t))
        else:
            parts.append(os.path.splitext(os.path.basename(t))[0])
    return "_".join(parts) + ".mp4"


def extract_structure(tokens: list) -> tuple:
    fade_in = 0
    fade_out = 0

    if not tokens:
        die("No arguments provided.")

    if isinstance(tokens[0], int):
        fade_in = tokens.pop(0)

    if not tokens:
        die("No clip files provided.")

    if isinstance(tokens[-1], int):
        fade_out = tokens.pop(-1)

    if not tokens:
        die("No clip files provided.")

    clips = []
    transitions = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if isinstance(tok, str):
            clips.append(tok)
            i += 1
            if i < len(tokens):
                if isinstance(tokens[i], int):
                    transitions.append(tokens[i])
                    i += 1
                elif isinstance(tokens[i], str):
                    transitions.append(1)  # default
        elif isinstance(tok, int):
            if clips:
                transitions.append(tok)
            i += 1

    return fade_in, clips, transitions, fade_out


def build_filtergraph(n, durations, transitions, fade_in, fade_out, keep_audio):
    filter_parts = []
    video_labels = []
    audio_labels = []

    for idx in range(n):
        vparts = []
        if idx == 0 and fade_in > 0:
            vparts.append(f"fade=t=in:st=0:d={fade_in}")
        if idx == n - 1 and fade_out > 0:
            start = max(0.0, durations[idx] - fade_out)
            vparts.append(f"fade=t=out:st={start:.4f}:d={fade_out}")

        if vparts:
            vlabel = f"pre_v{idx}"
            filter_parts.append(f"[{idx}:v]{','.join(vparts)}[{vlabel}]")
        else:
            vlabel = f"{idx}:v"

        video_labels.append(vlabel)
        if keep_audio:
            audio_labels.append(f"{idx}:a")

    current_vlabel = video_labels[0]
    current_alabel = audio_labels[0] if keep_audio else None
    cumulative_offset = 0.0

    for idx in range(1, n):
        T = transitions[idx - 1]
        cumulative_offset += durations[idx - 1] - T

        out_vlabel = f"xfv{idx}"
        filter_parts.append(
            f"[{current_vlabel}][{video_labels[idx]}]"
            f"xfade=transition=fade:duration={T}:offset={cumulative_offset:.6f}"
            f"[{out_vlabel}]"
        )
        current_vlabel = out_vlabel

        if keep_audio:
            out_alabel = f"xfa{idx}"
            filter_parts.append(
                f"[{current_alabel}][{audio_labels[idx]}]"
                f"acrossfade=d={T}"
                f"[{out_alabel}]"
            )
            current_alabel = out_alabel

    return ";".join(filter_parts), current_vlabel, current_alabel


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    tokens, keep_audio = parse_tokens(sys.argv[1:])
    tokens_for_name = list(tokens)

    fade_in, clips, transitions, fade_out = extract_structure(tokens)

    if not clips:
        die("No clip files found in arguments.")

    out_name = build_output_name(tokens_for_name)
    out_path = os.path.join(os.getcwd(), out_name)

    for clip in clips:
        if not os.path.isfile(clip):
            die(f"File not found: {clip!r}")

    with tempfile.TemporaryDirectory(prefix="clipconc_") as tmpdir:
        norm_paths = []
        for idx, clip in enumerate(clips):
            dst = os.path.join(tmpdir, f"norm_{idx:03d}.mp4")
            print(f"  normalizing [{idx+1}/{len(clips)}] {clip} ...", file=sys.stderr)
            normalize_clip(clip, dst, keep_audio)
            norm_paths.append(dst)

        durations = [ffprobe_duration(p) for p in norm_paths]
        n = len(norm_paths)

        if n == 1:
            vparts = []
            if fade_in > 0:
                vparts.append(f"fade=t=in:st=0:d={fade_in}")
            if fade_out > 0:
                start = max(0.0, durations[0] - fade_out)
                vparts.append(f"fade=t=out:st={start:.4f}:d={fade_out}")

            cmd = ["ffmpeg", "-y", "-i", norm_paths[0]]
            if vparts:
                cmd += ["-vf", ",".join(vparts)]
            if not keep_audio:
                cmd += ["-an"]
            cmd += ["-c:v", "libx264", "-preset", "ultrafast", out_path]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                die(f"ffmpeg single-clip failed:\n{result.stderr}")

        else:
            filtergraph, final_v, final_a = build_filtergraph(
                n, durations, transitions, fade_in, fade_out, keep_audio
            )

            cmd = ["ffmpeg", "-y"]
            for p in norm_paths:
                cmd += ["-i", p]

            cmd += ["-filter_complex", filtergraph, "-map", f"[{final_v}]"]
            if keep_audio and final_a:
                cmd += ["-map", f"[{final_a}]", "-c:a", "aac", "-b:a", "192k"]
            else:
                cmd += ["-an"]

            cmd += ["-c:v", "libx264", "-preset", "ultrafast", out_path]

            print(f"  compositing {n} clips ...", file=sys.stderr)
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                die(f"ffmpeg composite failed:\n{result.stderr}")

    print(os.path.abspath(out_path))


if __name__ == "__main__":
    main()