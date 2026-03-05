pmpv() {
  [ "$#" -lt 1 ] && { echo "Usage: pmpv DIR..." >&2; return 1; }

  # 1. Variables and Environment
  local hold="${PMPVHOLDFOR:-60}"
  local vidspeed="${PMPVVIDSPEED:-100}"
  local rescan="${PMPVRESCAN:-60}"
  local fs="${PMPVFS:-0}"
  local screen="${PMPVSCREEN:-}"

  echo "[pmpv] hold=$hold vidspeed=$vidspeed rescan=$rescan fs=$fs screen=${screen:-default}"
  echo "[pmpv] dirs: $*"

  local cache="${HOME}/.cache/pmpv"
  mkdir -p "$cache"

  local run_id
  run_id=$(date +%s)
  local sock="${cache}/pmpv-${run_id}.sock"
  local luas="${cache}/pmpv-${run_id}.lua"

  # 2. Generate Lua Script
  cat >"$luas" <<LUA
local mp = require 'mp'
local timer = nil

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

local function clear_timer()
  if timer then timer:kill(); timer = nil end
end

mp.register_event("file-loaded", function()
  clear_timer()
  local path = mp.get_property("path")

  if is_image(path) then
    mp.set_property_number("speed", 1.0)
    timer = mp.add_timeout(${hold}, function()
      mp.command("playlist-next force")
    end)
  else
    mp.set_property_number("speed", ${vidspeed} / 100.0)
  end
end)

mp.register_event("end-file", function()
  clear_timer()
  local path = mp.get_property("path")
  if is_video(path) then
    timer = mp.add_timeout(${hold}, function()
      mp.command("playlist-next force")
    end)
  end
end)
LUA

  # 3. Build playlist once (no background rescanning)
  mapfile -t files < <(
    find "$@" -type f \( \
      -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o \
      -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" \
    \) 2>/dev/null | shuf
  )

  [ ${#files[@]} -eq 0 ] && {
    echo "[pmpv] No media found."
    rm -f "$luas"
    return 1
  }

  # 4. mpv arguments
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

  # 5. Run in foreground (blocking)
  mpv "${mpv_args[@]}" "${files[@]}"

  # 6. Cleanup after mpv exits
  rm -f "$sock" "$luas"
}