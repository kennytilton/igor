#!/usr/bin/env python3
"""
credit_text.py - Render a styled text card to MP4.

Usage:
    credit_text.py <textfile> [output.mp4] [options]

Arguments:
    textfile         Text file to render (required). Each line rendered as-is.
                     Blank lines become half-height vertical spacers.
    output.mp4       Output path (optional, defaults to <textfile stem>.mp4)

Options:
    --duration N     Hold duration in seconds (default: 5)
    --fadein N       Fade-in seconds (default: 1.5)
    --fadeout N      Fade-out seconds (default: 1.5)
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
import subprocess
import sys
import tempfile


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


def render_frame(lines, width, height, fontsize, bg, fg, font_path):
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

    # Decorative rules
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


def png_to_mp4(png_bytes, out_path, duration, fadein, fadeout, width, height):
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        f.write(png_bytes)
        png_path = f.name

    total = duration + fadein + fadeout
    fade_out_start = total - fadeout

    vf = (
        f"fade=t=in:st=0:d={fadein},"
        f"fade=t=out:st={fade_out_start:.3f}:d={fadeout}"
    )

    cmd = [
        "ffmpeg", "-y",
        "-loop", "1", "-i", png_path,
        "-vf", vf,
        "-t", str(total),
        "-r", "30",
        "-pix_fmt", "yuv420p",
        "-c:v", "libx264", "-preset", "ultrafast",
        "-an",
        out_path
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(png_path)

    if result.returncode != 0:
        print(f"ffmpeg error:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="Render styled text card to MP4.")
    ap.add_argument("textfile",   help="Input text file")
    ap.add_argument("output",     nargs="?", default=None,
                    help="Output MP4 path (default: <textfile stem>.mp4)")
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

    if not os.path.isfile(args.textfile):
        print(f"credit_text.py error: file not found: {args.textfile!r}", file=sys.stderr)
        sys.exit(1)

    with open(args.textfile, "r", encoding="utf-8") as fh:
        raw = fh.read().rstrip("\n")
    lines = raw.split("\n")

    stem = os.path.splitext(os.path.basename(args.textfile))[0]
    out_path = os.path.abspath(args.output if args.output else stem + ".mp4")

    font_path = find_font(args.font)
    if font_path:
        print(f"  using font: {font_path}", file=sys.stderr)
    else:
        print("  warning: no TTF font found, using PIL default", file=sys.stderr)

    print(f"  rendering {len(lines)} lines ...", file=sys.stderr)
    png = render_frame(lines, args.width, args.height, args.fontsize,
                        args.bg, args.fg, font_path)

    print("  encoding MP4 ...", file=sys.stderr)
    png_to_mp4(png, out_path, args.duration, args.fadein, args.fadeout,
                args.width, args.height)

    print(out_path)


if __name__ == "__main__":
    main()
