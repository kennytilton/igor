gemmpvex() {
  if [ "$#" -lt 1 ]; then
    cat <<EOF
Usage: pmpvex DIR...
Between each main clip, play 1–3 random clips from DIR/gap (if it exists).
Does NOT descend into subdirectories (DIR and DIR/gap are maxdepth 1).
Hold (pause on last frame) for PMPVHOLDFOR seconds between items.
EOF
    return 1
  fi

  local hold="${PMPVHOLDFOR:-60}"
  local vidspeed="${PMPVVIDSPEED:-100}"
  local fs="${PMPVFS:-0}"
  local screen="${PMPVSCREEN:-}"

  echo "[pmpvex] hold=$hold vidspeed=$vidspeed fs=$fs screen=${screen:-default}"
  echo "[pmpvex] dirs: $*"
  echo "[pmpvex] Collecting media (no descent)..."

  local cache="${HOME}/.cache/pmpv"
  mkdir -p "$cache"

  local run_id
  run_id=$(date +%s)
  local sock="${cache}/pmpvex-${run_id}.sock"
  local luas="${cache}/pmpvex-${run_id}.lua"

  cat >"$luas" <<LUA
local mp = require 'mp'

local hold_timer = nil
local poll_timer = nil
local scheduled = false

local function is_image(path)
  if not path then return false end
  path = path:lower()
  return path:match('%.png$') or path:match('%.jpe?g$') or path:match('%.webp$')
end

local function is_video(path)
  if not path then return false end
  path = path:lower()
  return path:match('%.mp4$') or path:match('%.webm$') or
         path:match('%.mov$') or path:match('%.mkv$') or
         path:match('%.avi$')
end

local function kill_timer(t, name)
  if t then
    mp.msg.info("Killing "..name)
    t:kill()
  end
  return nil
end

local function reset_timers()
  hold_timer = kill_timer(hold_timer, "hold_timer")
  poll_timer = kill_timer(poll_timer, "poll_timer")
  scheduled = false
end

local function schedule_next(reason)
  if scheduled then
    return
  end
  scheduled = true
  poll_timer = kill_timer(poll_timer, "poll_timer")
  
  mp.msg.info("Scheduling next in ${hold}s, reason="..tostring(reason))
  hold_timer = mp.add_timeout(${hold}, function()
    mp.msg.info("Hold complete; playlist-next, reason="..tostring(reason))
    scheduled = false
    mp.command("playlist-next force")
  end)
end

local function start_video_end_watcher()
  poll_timer = mp.add_periodic_timer(0.10, function()
    local eof = mp.get_property_native("eof-reached")
    local pos = mp.get_property_number("time-pos", -1)
    local dur = mp.get_property_number("duration", -1)

    if eof == true then
      schedule_next("eof-reached")
      return
    end

    if dur > 0 and pos >= 0 then
      local remaining = dur - pos
      if remaining <= 0.12 then
        schedule_next("near-end")
        return
      end
    end
  end)
end

mp.register_event("file-loaded", function()
  reset_timers()
  local path = mp.get_property("path")
  local pos  = mp.get_property_number("playlist-pos", -1)
  mp.msg.info("file-loaded: pos="..tostring(pos).." path="..tostring(path))

  if is_image(path) then
    mp.set_property_number("speed", 1.0)
    schedule_next("image-hold")
    return
  end

  if is_video(path) then
    mp.set_property_number("speed", ${vidspeed} / 100.0)
    start_video_end_watcher()
    return
  end

  schedule_next("unknown-type")
end)

mp.register_event("end-file", function(event)
  if event.reason == "eof" and not scheduled then
    schedule_next("end-file-event")
  end
end)
LUA

  local main_files=()
  local gap_files=()

  for dir in "$@"; do
    while IFS= read -r -d '' f; do
      main_files+=("$f")
    done < <(
      find "$dir" -maxdepth 1 -type f \( \
        -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o \
        -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \
      \) -print0 2>/dev/null
    )

    if [ -d "$dir/gap" ]; then
      while IFS= read -r -d '' g; do
        gap_files+=("$g")
      done < <(
        find "$dir/gap" -maxdepth 1 -type f \( \
          -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o \
          -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \
        \) -print0 2>/dev/null
      )
    fi
  done

  if [ ${#main_files[@]} -eq 0 ]; then
    echo "[pmpvex] No main media found."
    rm -f "$luas"
    return 1
  fi

  # Shuffle main list
  mapfile -t main_files < <(printf "%s\n" "${main_files[@]}" | shuf)

  local files=()
  for f in "${main_files[@]}"; do
    files+=("$f")
    if [ ${#gap_files[@]} -gt 0 ]; then
      local n=$(( (RANDOM % 3) + 1 ))
      mapfile -t chosen < <(printf "%s\n" "${gap_files[@]}" | shuf -n "$n")
      for g in "${chosen[@]}"; do
        files+=("$g")
      done
    fi
  done

  echo "[pmpvex] Final playlist size=${#files[@]}"

  local mpv_args=(
    "--idle=no"
    "--force-window=yes"
    "--no-audio"
    "--no-osd-bar"
    "--input-ipc-server=$sock"
    "--script=$luas"
    "--image-display-duration=inf"
    "--keep-open=always"
  )

  [ "$fs" = "1" ] && mpv_args+=(--fs)
  if [ -n "$screen" ]; then
    mpv_args+=(--screen="$screen" --fs-screen="$screen")
  fi

  mpv "${mpv_args[@]}" "${files[@]}"

  rm -f "$sock" "$luas"
}