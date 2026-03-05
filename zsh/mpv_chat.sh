function chatmpv() {
  if [ "$#" -lt 1 ]; then
    cat <<'EOF'
Usage: chatmpv DIR...
Sequence: [Main] -> [1-3 pairs of REM + GAP]
No fades. Video speed: MPV_VIDSPEED. Image duration: MPV_IMGDUR.
Env:
  MPV_VIDSPEED  (default 100)   # percent
  MPV_IMGDUR    (default 5)     # seconds for images
  MPV_FSS       (fullscreen + screen number)  # adds --fs --fs-screen=<n>
EOF
    return 1
  fi

  local vidspeed="${MPV_VIDSPEED:-100}" img_dur="${MPV_IMGDUR:-5}" fss="${MPV_FSS:-}"
  echo "[chatmpv] vidspeed=$vidspeed img_dur=$img_dur fss=${fss:-none}"

  local cache="${HOME}/Library/Caches/pmpv"
  mkdir -p "$cache" || return 1
  local luas="${cache}/chatmpv-$(date +%s).lua"

  cat >"$luas" <<LUA
local mp = require 'mp'
mp.register_event("file-loaded", function()
  local p = (mp.get_property("path","")):lower()
  local is_img = p:match('%.png$') or p:match('%.jpe?g$') or p:match('%.webp$')
  if not is_img then mp.set_property_number("speed", ${vidspeed} / 100.0) end
end)
LUA

  local -a main_files gap_files rem_files final_list mpv_args
  local dir f g r n i rem_pick gap_pick

  for dir in "$@"; do
    while IFS= read -r -d '' f; do main_files+=("$f"); done < <(
      find "$dir" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \) -print0 2>/dev/null
    )
    [ -d "$dir/gap" ] && while IFS= read -r -d '' g; do gap_files+=("$g"); done < <(
      find "$dir/gap" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \) -print0 2>/dev/null
    )
    [ -d "$dir/rem" ] && while IFS= read -r -d '' r; do rem_files+=("$r"); done < <(
      find "$dir/rem" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \) -print0 2>/dev/null
    )
  done

  if [ ${#main_files[@]} -eq 0 ]; then
    echo "[chatmpv] Error: No main files found."
    rm -f "$luas"
    return 1
  fi

  main_files=("${(@Oa)main_files}")  # zsh shuffle

  for f in "${main_files[@]}"; do
    final_list+=("$f")
    if [ ${#gap_files[@]} -gt 0 ] && [ ${#rem_files[@]} -gt 0 ]; then
      n=$(( (RANDOM % 3) + 1 ))
      for (( i=1; i<=n; i++ )); do
        rem_pick="${rem_files[$(( (RANDOM % ${#rem_files[@]}) + 1 ))]}"
        gap_pick="${gap_files[$(( (RANDOM % ${#gap_files[@]}) + 1 ))]}"
        final_list+=("$rem_pick" "$gap_pick")
      done
    fi
  done

  mpv_args=(--force-window=yes --no-audio --no-osd-bar --script="$luas" --image-display-duration="$img_dur" --loop-playlist=inf --keep-open=no)
  [ -n "$fss" ] && mpv_args+=(--fs --fs-screen="$fss")

  mpv "${mpv_args[@]}" "${final_list[@]}"
  local rc=$?

  rm -f "$luas"
  return $rc
}