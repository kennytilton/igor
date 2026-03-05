mpv_gem() {
  if [[ "$#" -lt 1 ]]; then
    cat <<EOF
Usage: mpv_gem expects DIR...
EOF
    return 1
  fi

  local vidspeed="${MPV_VIDSPEED:-100}" img_dur="${MPV_IMGDUR:-5}" fss_val="${MPV_FSS:-}"
  local cache="${HOME}/.cache/pmpv"
  mkdir -p "$cache"
  local luas="${cache}/gem_ex-$(date +%s).lua"

  local main_files=() gap_files=() rem_files=() idle_files=()

  # 1. Collect and Count
  for dir in "$@"; do
    main_files+=( ${(f)"$(find "$dir" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \) 2>/dev/null)"} )
    [[ -d "$dir/gap" ]] && gap_files+=( ${(f)"$(find "$dir/gap" -maxdepth 1 -type f -iname "*.*" 2>/dev/null)"} )
    [[ -d "$dir/rem" ]] && rem_files+=( ${(f)"$(find "$dir/rem" -maxdepth 1 -type f -iname "*.*" 2>/dev/null)"} )
    [[ -d "$dir/idle" ]] && idle_files+=( ${(f)"$(find "$dir/idle" -maxdepth 1 -type f -iname "*.*" 2>/dev/null)"} )
  done

  main_files=( "${main_files[@]:#}" )
  gap_files=( "${gap_files[@]:#}" )
  rem_files=( "${rem_files[@]:#}" )
  idle_files=( "${idle_files[@]:#}" )

  # --- PRE-FLIGHT INVENTORY ---
  echo "------------------------------------------"
  echo "FOUND: ${#main_files} Main clips"
  echo "FOUND: ${#rem_files} REM clips"
  echo "FOUND: ${#gap_files} Gap clips"
  echo "FOUND: ${#idle_files} Idle clips"
  echo "------------------------------------------"

  if (( ${#main_files} == 0 )); then 
    echo "[mpv_gem] Error: No main files found."
    rm -f "$luas"; return 1
  fi

  # 2. Build Playlist with Markers
  # We use dummy files or property changes to signal transitions to Lua
  local shuffled_main=( ${(f)"$(printf "%s\n" "${main_files[@]}" | sort --random-sort)"} )
  local final_list=()

  for f in "${shuffled_main[@]}"; do
    final_list+=("$f")
    
    if (( ${#gap_files} > 0 && ${#rem_files} > 0 )); then
      local n=$(( (RANDOM % 3) + 1 ))
      for ((i=1; i<=n; i++)); do
        final_list+=( "$(printf "%s\n" "${rem_files[@]}" | sort --random-sort | head -n 1)" )
        final_list+=( "$(printf "%s\n" "${gap_files[@]}" | sort --random-sort | head -n 1)" )
      done
    fi

    if (( ${#idle_files} > 0 )); then
      final_list+=( ${(f)"$(printf "%s\n" "${idle_files[@]}" | sort --random-sort)"} )
    fi
  done

  # 3. Hardened Lua for Transition Alerts
  cat >"$luas" <<LUA
local mp = require 'mp'
local last_cat = ""

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", ""):lower()
    local cat = "MAIN"
    
    if path:find("/gap/") then cat = "GAP"
    elseif path:find("/idle/") then cat = "IDLE"
    elseif path:find("/rem/") then cat = "REM"
    end

    -- Signal entering/exiting a sequence
    if cat ~= last_cat then
        if last_cat ~= "" then print("<<< ENDING " .. last_cat .. " SEQUENCE") end
        print("\n>>> STARTING " .. cat .. " SEQUENCE")
        last_cat = cat
    end

    print(string.format("    Playing: %s", path:match("([^/]+)$")))
    
    local is_img = path:match('%.png$') or path:match('%.jpe?g$') or path:match('%.webp$')
    if not is_img then
        mp.set_property_number("speed", ${vidspeed} / 100.0)
    end
end)
LUA

  local mpv_args=(
    --no-config --force-window=yes --no-audio --ao=null --no-osd-bar
    --script="$luas" --image-display-duration="$img_dur" --loop-playlist=inf
    --keep-open=no --ontop --msg-level=all=status,script=info
  )

  [[ -n "$fss_val" ]] && mpv_args+=( --fs "--fs-screen=$fss_val" "--screen=$fss_val" )

  mpv "${mpv_args[@]}" "${final_list[@]}"
  rm -f "$luas"
}