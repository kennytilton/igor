#!/usr/bin/env python3
"""
Author: Gemini
Date: 2026-03-02 08:48:00
Description: Dynamic MP4 xfade concatenation with initial/final fade-in/out support.
"""

import os
import sys
import subprocess

def get_dur(filename):
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', filename]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return float(result.stdout.strip())

def clipconc(*args, include_audio=False):
    files = []
    provided_parts = []
    
    # Initialize fade variables
    initial_fade = 0
    final_fade = 0
    internal_fades = []

    # 1. Parse Args & Logic
    arg_list = list(args)
    if not arg_list: return

    # Check for initial fade-in integer
    if isinstance(arg_list[0], int):
        initial_fade = arg_list.pop(0)
        provided_parts.append(str(initial_fade))

    # Check for final fade-out integer
    if arg_list and isinstance(arg_list[-1], int):
        final_fade = arg_list.pop()
        # We'll append this to name later to maintain order

    # Process remaining files and internal fades
    i = 0
    while i < len(arg_list):
        item = arg_list[i]
        if isinstance(item, str):
            clean = item[:-4] if item.lower().endswith(".mp4") else item
            path = f"{clean}.mp4"
            if not os.path.exists(path):
                print(f"Error: {path} not found.")
                return
            files.append(path)
            provided_parts.append(clean)
            
            # Look for internal fade between clips
            if i + 1 < len(arg_list) and isinstance(arg_list[i+1], int):
                internal_fades.append(arg_list[i+1])
                provided_parts.append(str(arg_list[i+1]))
                i += 2
            else:
                if i + 1 < len(arg_list):
                    internal_fades.append(1) # Default internal fade
                i += 1
        else:
            i += 1

    if final_fade > 0:
        provided_parts.append(str(final_fade))

    if len(files) < 1: return

    output_base = "_".join(provided_parts)
    output_filename = f"{output_base}.mp4"
    
    # 2. Build FFmpeg Command
    input_flags = []
    prep_filters = []
    
    for idx, f in enumerate(files):
        input_flags.extend(["-i", f])
        f_dur = get_dur(f)
        
        # Base normalization
        filter_chain = f"scale=1280:720,setdar=16/9,fps=30"
        
        # Apply initial fade-in to the first clip only
        if idx == 0 and initial_fade > 0:
            filter_chain += f",fade=t=in:st=0:d={initial_fade}"
            
        # Apply final fade-out to the last clip only
        if idx == len(files) - 1 and final_fade > 0:
            filter_chain += f",fade=t=out:st={f_dur - final_fade}:d={final_fade}"
            
        prep_filters.append(f"[{idx}:v]{filter_chain}[v{idx}]")

    # 3. Handle Transitions (xfade)
    xfade_filters = []
    if len(files) > 1:
        current_total_duration = get_dur(files[0])
        last_v_label = "[v0]"
        
        for idx in range(1, len(files)):
            fade_dur = internal_fades[idx-1]
            offset = current_total_duration - fade_dur
            next_v_label = f"[v_tmp{idx}]" if idx < len(files) - 1 else "[outv]"
            xfade_filters.append(f"{last_v_label}[v{idx}]xfade=transition=fade:duration={fade_dur}:offset={offset}{next_v_label}")
            current_total_duration = (current_total_duration + get_dur(files[idx])) - fade_dur
            last_v_label = next_v_label
    else:
        # If only one file, just map the prepped version
        prep_filters[-1] = prep_filters[-1].replace("[v0]", "[outv]")

    filter_complex = ";".join(prep_filters + xfade_filters)
    
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error"
    ] + input_flags + [
        "-filter_complex", filter_complex,
        "-map", "[outv]",
        "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
        "-preset", "ultrafast", "-an", 
        output_filename
    ]

    # 4. Execution & Reporting
    try:
        subprocess.run(cmd, check=True)
        print(os.path.abspath(output_filename))
    except subprocess.CalledProcessError as e:
        print(f"FFmpeg Error: {e}")

if __name__ == "__main__":
    use_audio = "--audio" in sys.argv
    cleaned_args = [x for x in sys.argv[1:] if x != "--audio"]
    passed_args = [int(x) if x.isdigit() else x for x in cleaned_args]
    clipconc(*passed_args, include_audio=use_audio)