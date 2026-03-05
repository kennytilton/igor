mpv_gem() {
  if [[ "$#" -lt 1 ]]; then
    cat <<EOF
Usage: mpv_gem DIR...
Options: 
  MPV_FADE      (default 0.4) # Fade-to-Black duration
  MPV_VIDSPEED  (default 100)
  MPV_FSS       (Fullscreen ID)
EOF
    return 1
  fi

  local vidspeed="${MPV_VIDSPEED:-100}"
  local fss_val="${MPV_FSS:-}"
  # Ensure fade is positive for the filter
  local fade_raw="${MPV_FADE:-0.4}"
  local fade_dur=${fade_raw#-} 
  
  local cache="${HOME}/.cache/pmpv"
  mkdir -p "$cache"
  local luas="${cache}/gem_ex-$(date +%s).lua"

  local main_files=() gap_files=() idle_files=()
  for dir in "$@"; do
    main_files+=( ${(f)"$(find "$dir" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" \) 2>/dev/null)"} )
    [[ -d "$dir/gap" ]] && gap_files+=( ${(f)"$(find "$dir/gap" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) 2>/dev/null)"} )
    [[ -d "$dir/idle" ]] && idle_files+=( ${(f)"$(find "$dir/idle" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) 2>/dev/null)"} )
  done

  main_files=( "${main_files[@]:#}" ); gap_files=( "${gap_files[@]:#}" ); idle_files=( "${idle_files[@]:#}" )

  # 1. Lua: Speed, Logging, and Reliable Fades
  cat >"$luas" <<LUA
local mp = require 'mp'
local last_cat = ""

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", ""):lower()
    local duration = mp.get_property_number("duration", 0)
    local cat = "MAIN"
    
    if path:find("/gap/") then cat = "GAP"
    elseif path:find("/idle/") then cat = "IDLE"
    end

    if cat ~= last_cat then
        if last_cat ~= "" then print("<<< ENDING " .. last_cat) end
        print("\n>>> STARTING " .. cat)
        last_cat = cat
    end
    print(string.format("    Playing: %s (%.2fs) | Fade: ${fade_dur}s", path:match("([^/]+)$"), duration))

    -- Apply Playback Speed
    mp.set_property_number("speed", ${vidspeed} / 100.0)

    -- Reliable Fade-to-Black Filter
    local st_out = math.max(0, duration - ${fade_dur})
    local vf = string.format("format=yuv420p,fade=t=in:st=0:d=${fade_dur},fade=t=out:st=%.2f:d=${fade_dur}", st_out)
    mp.commandv("vf", "set", vf)
end)
LUA

  # 2. Assemble Playlist
  local shuffled_main=( ${(f)"$(printf "%s\n" "${main_files[@]}" | sort --random-sort)"} )
  local final_list=()
  for f in "${shuffled_main[@]}"; do
    final_list+=("$f")
    if (( ${#gap_files} > 0 )); then
      local n=$(( (RANDOM % 3) + 1 ))
      for ((i=1; i<=n; i++)); do
        final_list+=( "$(printf "%s\n" "${gap_files[@]}" | sort --random-sort | head -n 1)" )
      done
    fi
    if (( ${#idle_files} > 0 )); then
      final_list+=( ${(f)"$(printf "%s\n" "${idle_files[@]}" | sort --random-sort)"} )
    fi
  done

  # 3. Execution
  local mpv_args=(
    --no-config --force-window=yes --no-audio --ao=null --no-osd-bar
    --script="$luas" --loop-playlist=inf --keep-open=no --ontop
    --msg-level=all=status,script=info --hwdec=auto-safe
  )

  [[ -n "$fss_val" ]] && mpv_args+=( --fs "--fs-screen=$fss_val" "--screen=$fss_val" )

  mpv "${mpv_args[@]}" "${final_list[@]}"
  rm -f "$luas"
}