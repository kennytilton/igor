mpv_claude () {
  if [ "$#" -lt 1 ]; then
    cat <<EOF
Usage: gem_mpv_ex DIR...
Sequence: [Main] -> [1-3 pairs of REM + GAP]
No fades. Speed: PMPVVIDSPEED. Image Duration: PMPVIMGDUR.
EOF
    return 1
  fi

  local vidspeed="${PMPVVIDSPEED:-100}"
  local fs="${PMPVFS:-0}"
  local screen="${PMPVSCREEN:-}"
  local img_dur="${PMPVIMGDUR:-5}"
  echo "[gem_mpv_ex] vidspeed=$vidspeed fs=$fs screen=${screen:-default} img_dur=$img_dur"

  local cache="${HOME}/.cache/pmpv"
  mkdir -p "$cache"
  local luas="${cache}/gem_ex-$(date +%s).lua"

  cat >"$luas" <<LUA
local mp = require 'mp'
mp.register_event("file-loaded", function()
    local path = mp.get_property("path", ""):lower()
    local is_img = path:match('%.png$') or path:match('%.jpe?g$') or path:match('%.webp$')
    if not is_img then
        mp.set_property_number("speed", ${vidspeed} / 100.0)
    end
end)
LUA

  local main_files=()
  local gap_files=()
  local rem_files=()

  local tmpM=$(mktemp)
  local tmpG=$(mktemp)
  local tmpR=$(mktemp)

  for dir in "$@"; do
    find "$dir" -maxdepth 1 -type f \( \
      -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o \
      -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \
    \) 2>/dev/null >> "$tmpM"

    if [ -d "$dir/gap" ]; then
      find "$dir/gap" -maxdepth 1 -type f \( \
        -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o \
        -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \
      \) 2>/dev/null >> "$tmpG"
    fi

    if [ -d "$dir/rem" ]; then
      find "$dir/rem" -maxdepth 1 -type f \( \
        -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o \
        -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \
      \) 2>/dev/null >> "$tmpR"
    fi
  done

  while IFS= read -r f; do main_files+=("$f"); done < "$tmpM"
  while IFS= read -r g; do gap_files+=("$g"); done < "$tmpG"
  while IFS= read -r r; do rem_files+=("$r"); done < "$tmpR"
  rm -f "$tmpM" "$tmpG" "$tmpR"

  if [ ${#main_files[@]} -eq 0 ]; then
    echo "[gem_mpv_ex] Error: No main files found."
    rm -f "$luas"
    return 1
  fi

  # macOS has no shuf; use python3
  _shuf_all() { python3 -c "import sys,random; L=sys.stdin.read().splitlines(); random.shuffle(L); print('\n'.join(L))"; }
  _shuf_one() { python3 -c "import sys,random; L=sys.stdin.read().splitlines(); print(random.choice(L)) if L else None"; }

  local shuffled_main=()
  while IFS= read -r f; do shuffled_main+=("$f"); done < <(printf "%s\n" "${main_files[@]}" | _shuf_all)

  local final_list=()
  for f in "${shuffled_main[@]}"; do
    final_list+=("$f")

    if [ ${#gap_files[@]} -gt 0 ] && [ ${#rem_files[@]} -gt 0 ]; then
      local n=$(( (RANDOM % 3) + 1 ))
      local i
      for ((i=0; i<n; i++)); do
        final_list+=("$(printf "%s\n" "${rem_files[@]}" | _shuf_one)")
        final_list+=("$(printf "%s\n" "${gap_files[@]}" | _shuf_one)")
      done
    fi
  done

  local mpv_args=(
    "--force-window=yes"
    "--no-audio"
    "--no-osd-bar"
    "--script=$luas"
    "--image-display-duration=$img_dur"
    "--loop-playlist=inf"
    "--keep-open=no"
  )

  [ "$fs" = "1" ] && mpv_args+=(--fs)
  [ -n "$screen" ] && mpv_args+=(--screen="$screen" --fs-screen="$screen")

  mpv "${mpv_args[@]}" "${final_list[@]}"
  rm -f "$luas"
}