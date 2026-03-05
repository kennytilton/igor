# pmpvex is a foreground mpv-based slideshow player for mixed media (videos + images) with optional “gap” inserts.

# High-level behavior:

# Input

# Takes one or more directories as arguments.

# Looks only at files directly inside each DIR (no recursion).

# If DIR/gap exists, it also looks only at files directly inside that subdirectory.

# Playlist Construction

# Collects all media files (png, jpg, webp, mp4, webm, mov, mkv, avi) directly inside each DIR as “main” clips.

# Collects media files directly inside each DIR/gap as “gap” clips.

# Shuffles the main clips.

# After each main clip, inserts 1–3 randomly selected gap clips (if any exist).

# Builds a single expanded playlist in memory before launching mpv.

# Playback

# Runs mpv in the foreground.

# Disables audio and OSD bar.

# Optionally fullscreen and screen selection via env vars.

# Videos play at PMPVVIDSPEED percent (default 100).

# Images are shown indefinitely until advanced by the script.

# Hold Behavior

# When a video reaches its last frame, mpv freezes on that frame.

# The script waits PMPVHOLDFOR seconds (default 60).

# After the hold, it advances to the next playlist item.

# Images are held for the same duration before advancing.

# No Recursion

# Main clips: only DIR/*

# Gap clips: only DIR/gap/*

# No descent into deeper subdirectories.

# Termination

# Runs blocking in the terminal.

# When mpv exits, temporary Lua and IPC files are cleaned up.

# In short:

# pmpvex = shuffled slideshow player that inserts 1–3 random “gap” clips between each primary clip, and pauses on the last frame of every item for a fixed number of seconds before advancing.

pmpvex() {
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
    mp.msg.info("schedule_next ignored (already scheduled), reason="..tostring(reason))
    return
  end
  scheduled = true
  poll_timer = kill_timer(poll_timer, "poll_timer")
  mp.msg.info("Scheduling next in ${hold}s, reason="..tostring(reason))
  hold_timer = mp.add_timeout(${hold}, function()
    mp.msg.info("Hold complete; playlist-next, reason="..tostring(reason))
    mp.command("playlist-next force")
  end)
end

local function start_video_end_watcher()
  poll_timer = mp.add_periodic_timer(0.10, function()
    -- Read current state (do not rely on property-change events)
    local eof = mp.get_property_native("eof-reached")
    local pos = mp.get_property_number("time-pos", -1)
    local dur = mp.get_property_number("duration", -1)

    if eof == true then
      mp.msg.info(string.format("Watcher: eof-reached=true (pos=%.3f dur=%.3f)", pos, dur))
      schedule_next("eof-reached")
      return
    end

    -- duration/time-pos heuristic (covers cases where eof-reached is flaky)
    if dur > 0 and pos >= 0 then
      local remaining = dur - pos
      if remaining <= 0.08 then
        mp.msg.info(string.format("Watcher: near-end remaining=%.3f (pos=%.3f dur=%.3f)", remaining, pos, dur))
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
    mp.msg.info("Image detected; hold ${hold}s then next")
    mp.set_property_number("speed", 1.0)
    schedule_next("image-hold")
    return
  end

  if is_video(path) then
    mp.msg.info("Video detected; speed=${vidspeed}% (starting end watcher)")
    mp.set_property_number("speed", ${vidspeed} / 100.0)
    start_video_end_watcher()
    return
  end

  mp.msg.info("Unknown type; advancing in ${hold}s")
  schedule_next("unknown-type")
end)

-- Defensive: if mpv emits end-file (some builds do even with keep-open),
-- treat it as an end signal too.
mp.register_event("end-file", function()
  local path = mp.get_property("path")
  mp.msg.info("end-file event: " .. tostring(path))
  if is_video(path) then
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

  echo "[pmpvex] main_files=${#main_files[@]}"
  echo "[pmpvex] gap_files=${#gap_files[@]}"

  if [ ${#main_files[@]} -eq 0 ]; then
    echo "[pmpvex] No main media found."
    rm -f "$luas"
    return 1
  fi

  mapfile -t main_files < <(printf "%s\n" "${main_files[@]}" | shuf)

  local files=()
  for f in "${main_files[@]}"; do
    echo "[pmpvex] Adding main: $f"
    files+=("$f")

    if [ ${#gap_files[@]} -gt 0 ]; then
      local n=$(( (RANDOM % 3) + 1 ))
      echo "[pmpvex] Selecting $n gap clip(s)"
      mapfile -t chosen < <(printf "%s\n" "${gap_files[@]}" | shuf -n "$n")
      for g in "${chosen[@]}"; do
        echo "[pmpvex]   Adding gap: $g"
        files+=("$g")
      done
    fi
  done

  echo "[pmpvex] Final playlist size=${#files[@]}"
  echo "[pmpvex] Launching mpv..."

  local mpv_args=(
    "--idle=no"
    "--force-window=yes"
    "--no-audio"
    "--no-osd-bar"
    "--input-ipc-server=$sock"
    "--script=$luas"
    "--image-display-duration=inf"
    "--keep-open=always"
    "--msg-level=all=info"
  )

  [ "$fs" = "1" ] && mpv_args+=(--fs)
  if [ -n "$screen" ]; then
    mpv_args+=(--screen="$screen" --fs-screen="$screen")
  fi

  mpv "${mpv_args[@]}" "${files[@]}"

  rm -f "$sock" "$luas"
}