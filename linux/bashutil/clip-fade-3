clip-fade-3() {
    if [ "$#" -lt 4 ]; then
        echo "Usage: clip-fade-3 <c1> <c2> <c3> <output_name>"
        return 1
    fi

    # 1. Normalize filenames (ensure .mp4 extension)
    local f1="${1%.mp4}.mp4"
    local f2="${2%.mp4}.mp4"
    local f3="${3%.mp4}.mp4"
    local out="${4%.mp4}.mp4"

    # Verify files exist
    for f in "$f1" "$f2" "$f3"; do
        if [ ! -f "$f" ]; then echo "Error: $f not found"; return 1; fi
    done

    echo "[clip-fade-3] Processing $f1, $f2, $f3 -> $out"

    # 2. Get durations for offset math
    get_dur() { ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"; }
    local d1=$(get_dur "$f1")
    local d2=$(get_dur "$f2")

    # 3. Calculate Offsets (1s fade duration)
    # Offset 1: End of clip 1 minus 1s
    local off1=$(echo "$d1 - 1" | bc)
    # Offset 2: (Clip 1 + Clip 2) minus 2s (for two 1s fades)
    local off2=$(echo "$d1 + $d2 - 2" | bc)

    # 4. The FFmpeg Chain
    # We scale to 1280:720 and force 30fps to ensure the iPad plays it smoothly
    ffmpeg -i "$f1" -i "$f2" -i "$f3" -filter_complex \
        "[0:v]scale=1280:720,setdar=16/9,fps=30[v0]; \
         [1:v]scale=1280:720,setdar=16/9,fps=30[v1]; \
         [2:v]scale=1280:720,setdar=16/9,fps=30[v2]; \
         [v0][v1]xfade=transition=fade:duration=1:offset=$off1[v01]; \
         [v01][v2]xfade=transition=fade:duration=1:offset=$off2[outv]" \
        -map "[outv]" \
        -c:v libx264 -crf 18 -pix_fmt yuv420p \
        "$out"

    echo "[clip-fade-3] Done: $out"
}

