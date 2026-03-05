#!/usr/bin/env python3
"""
credit_text.py - Render a credits sequence to a single MP4.

Usage:
    credit_text.py <file1> [file2 ...] [output.mp4] [options]

Each input file is resolved by probing extensions in order: .mp4 .txt .png .jpg
  - .mp4  : included as-is (normalized to 1280x720 30fps)
  - .txt  : rendered as text card(s); use "---" to separate multiple cards
  - .png/.jpg : rendered as image card

Output filename defaults to all input stems joined by underscore + .mp4

Options:
    --duration N     Hold duration per card in seconds (default: 5)
    --fadein N       Fade-in seconds per card (default: 1.5)
    --fadeout N      Fade-out seconds per card (default: 1.5)
    --width N        Frame width (default: 1280)
    --height N       Frame height (default: 720)
    --fontsize N     Base font size (default: 52)
    --bg COLOR       Background hex color (default: #0a0a0a)
    --fg COLOR       Text hex color (default: #e8e0d0)
    --font PATH      Path to .ttf font file (optional, uses system serif if omitted)
"""

import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile


def die(msg):
    print(f"credit_text.py error: {msg}", file=sys.stderr)
    sys.exit(1)


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


def find_font(preferred=None):
    if preferred and os.path.isfile(preferred):
        return preferred
    candidates = [
        "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSerif.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
        "/usr/share/fonts/truetype/gentium/Gentium-R.ttf",
        "/usr/share/fonts/opentype/urw-base35/URWPalladioL-Roma.otf",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def resolve_file(name):
    """Resolve a filename by probing .mp4 .txt .png .jpg if no extension given."""
    if os.path.isfile(name):
        return name
    base, ext = os.path.splitext(name)
    if ext:
        die(f"file not found: {name!r}")
    for try_ext in (".mp4", ".txt", ".png", ".jpg"):
        candidate = name + try_ext
        if os.path.isfile(candidate):
            return candidate
    die(f"file not found (tried .mp4 .txt .png .jpg): {name!r}")


def split_cards(raw):
    """Split raw text into list of line-lists, separated by '---'."""
    cards = []
    current = []
    for line in raw.split("\n"):
        if line.strip() == "---":
            if current:
                cards.append(current)
            current = []
        else:
            current.append(line)
    if current:
        cards.append(current)
    cleaned = []
    for card in cards:
        while card and card[0] == "":
            card.pop(0)
        while card and card[-1] == "":
            card.pop()
        if card:
            cleaned.append(card)
    return cleaned


def render_text_frame(lines, width, height, fontsize, bg, fg, font_path):
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        print("Installing Pillow...", file=sys.stderr)
        subprocess.run([sys.executable, "-m", "pip", "install", "Pillow",
                        "--break-system-packages", "-q"], check=True)
        from PIL import Image, ImageDraw, ImageFont

    bg_rgb = hex_to_rgb(bg)
    fg_rgb = hex_to_rgb(fg)

    img = Image.new("RGB", (width, height), bg_rgb)
    draw = ImageDraw.Draw(img)

    font = None
    if font_path:
        try:
            font = ImageFont.truetype(font_path, fontsize)
        except Exception:
            pass
    if font is None:
        try:
            font = ImageFont.truetype(find_font(None), fontsize)
        except Exception:
            font = ImageFont.load_default()

    line_spacing = int(fontsize * 1.55)
    half_spacing = line_spacing // 2
    total_h = sum(half_spacing if ln == "" else line_spacing for ln in lines)

    y = (height - total_h) // 2
    for line in lines:
        if line == "":
            y += half_spacing
            continue
        bbox = draw.textbbox((0, 0), line, font=font)
        line_w = bbox[2] - bbox[0]
        x = (width - line_w) // 2
        draw.text((x, y), line, font=font, fill=fg_rgb)
        y += line_spacing

    rule_w = int(width * 0.20)
    rx = (width - rule_w) // 2
    block_top = (height - total_h) // 2
    block_bot = block_top + total_h
    rule_color = tuple(int(c * 0.55) for c in fg_rgb)
    gap = int(fontsize * 0.6)
    draw.line([(rx, block_top - gap), (rx + rule_w, block_top - gap)],
              fill=rule_color, width=2)
    draw.line([(rx, block_bot + gap), (rx + rule_w, block_bot + gap)],
              fill=rule_color, width=2)

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def image_to_mp4(src_path, out_path, duration, fadein, fadeout, width, height):
    """Render a PNG/JPG to MP4 with fade in/out."""
    total = duration + fadein + fadeout
    fade_out_start = total - fadeout
    vf = (
        f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,"
        f"format=yuv420p,"
        f"fade=t=in:st=0:d={fadein},"
        f"fade=t=out:st={fade_out_start:.3f}:d={fadeout}"
    )
    cmd = [
        "ffmpeg", "-y",
        "-loop", "1", "-i", src_path,
        "-vf", vf,
        "-t", str(total),
        "-r", "30",
        "-pix_fmt", "yuv420p",
        "-c:v", "libx264", "-preset", "ultrafast",
        "-an", out_path
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"ffmpeg image→mp4 failed:\n{result.stderr}")


def png_bytes_to_mp4(png_bytes, out_path, duration, fadein, fadeout, width, height):
    """Write png bytes to temp file then encode to MP4."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        f.write(png_bytes)
        tmp = f.name
    try:
        image_to_mp4(tmp, out_path, duration, fadein, fadeout, width, height)
    finally:
        os.unlink(tmp)


def normalize_mp4(src_path, out_path, width, height):
    """Normalize an MP4 to standard resolution/fps/format, preserving fade as-is."""
    vf = (
        f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,"
        f"fps=30,format=yuv420p"
    )
    cmd = [
        "ffmpeg", "-y", "-i", src_path,
        "-vf", vf,
        "-c:v", "libx264", "-preset", "ultrafast",
        "-an", out_path
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"ffmpeg normalize failed:\n{result.stderr}")


def concat_mp4s(clip_paths, out_path):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        for p in clip_paths:
            f.write(f"file '{p}'\n")
        list_path = f.name
    cmd = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0",
        "-i", list_path,
        "-c", "copy",
        out_path
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(list_path)
    if result.returncode != 0:
        die(f"ffmpeg concat failed:\n{result.stderr}")


def main():
    ap = argparse.ArgumentParser(description="Render credits sequence to MP4.")
    ap.add_argument("inputs", nargs="+",
                    help="Input files (no ext probes .mp4 .txt .png .jpg). "
                         "Last arg used as output if it ends in .mp4.")
    ap.add_argument("--duration", type=float, default=5.0)
    ap.add_argument("--fadein",   type=float, default=1.5)
    ap.add_argument("--fadeout",  type=float, default=1.5)
    ap.add_argument("--width",    type=int,   default=1280)
    ap.add_argument("--height",   type=int,   default=720)
    ap.add_argument("--fontsize", type=int,   default=52)
    ap.add_argument("--bg",       default="#0a0a0a")
    ap.add_argument("--fg",       default="#e8e0d0")
    ap.add_argument("--font",     default=None)
    args = ap.parse_args()

    # Detect if last positional arg is the output path
    inputs = args.inputs
    if len(inputs) > 1 and inputs[-1].lower().endswith(".mp4") and not os.path.isfile(inputs[-1]):
        explicit_out = inputs[-1]
        inputs = inputs[:-1]
    else:
        explicit_out = None

    # Resolve all input files
    resolved = [resolve_file(f) for f in inputs]

    # Build default output name from input stems
    stems = [os.path.splitext(os.path.basename(r))[0] for r in resolved]
    default_out = "_".join(stems) + ".mp4"
    out_path = os.path.abspath(explicit_out if explicit_out else default_out)

    font_path = find_font(args.font)
    if font_path:
        print(f"  using font: {font_path}", file=sys.stderr)

    with tempfile.TemporaryDirectory(prefix="credit_text_") as tmpdir:
        clip_paths = []
        clip_idx = 0

        for src in resolved:
            ext = os.path.splitext(src)[1].lower()
            print(f"  processing: {src}", file=sys.stderr)

            if ext == ".mp4":
                norm_path = os.path.join(tmpdir, f"clip_{clip_idx:03d}.mp4")
                normalize_mp4(src, norm_path, args.width, args.height)
                clip_paths.append(norm_path)
                clip_idx += 1

            elif ext in (".png", ".jpg", ".jpeg"):
                clip_path = os.path.join(tmpdir, f"clip_{clip_idx:03d}.mp4")
                image_to_mp4(src, clip_path, args.duration, args.fadein, args.fadeout,
                              args.width, args.height)
                clip_paths.append(clip_path)
                clip_idx += 1

            elif ext == ".txt":
                with open(src, "r", encoding="utf-8") as fh:
                    raw = fh.read().rstrip("\n")
                cards = split_cards(raw)
                if not cards:
                    die(f"no content in {src!r}")
                for lines in cards:
                    png = render_text_frame(lines, args.width, args.height,
                                             args.fontsize, args.bg, args.fg, font_path)
                    clip_path = os.path.join(tmpdir, f"clip_{clip_idx:03d}.mp4")
                    png_bytes_to_mp4(png, clip_path, args.duration, args.fadein,
                                      args.fadeout, args.width, args.height)
                    clip_paths.append(clip_path)
                    clip_idx += 1

            else:
                die(f"unsupported file type: {src!r}")

        if not clip_paths:
            die("no clips to assemble.")

        if len(clip_paths) == 1:
            shutil.copy(clip_paths[0], out_path)
        else:
            print(f"  concatenating {len(clip_paths)} clip(s) ...", file=sys.stderr)
            concat_mp4s(clip_paths, out_path)

    print(out_path)


if __name__ == "__main__":
    main()
