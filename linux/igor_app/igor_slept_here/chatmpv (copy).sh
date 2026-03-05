pmpv() {
  [ "$#" -lt 1 ] && { echo "Usage: pmpv DIR..." >&2; return 1; }

  # 1. Variables and Environment
  local hold="${PMPVHOLDFOR:-60}"
  local vidspeed="${PMPVVIDSPEED:-100}"
  local rescan="${PMPVRESCAN:-60}"
  local fs="${PMPVFS:-0}"
  local screen="${PMPVSCREEN:-}"
  
  local cache="${HOME}/.cache/pmpv"
  mkdir -p "$cache"

  local run_id=$(date +%s)
  local sock="${cache}/pmpv-${run_id}.sock"
  local luas="${cache}/pmpv-${run_id}.lua"

  # 2. Generate the Lua Script
  cat >"$luas" <<LUA
local mp = require 'mp'
local timer = nil
mp.register_event("file-loaded", function()
    if timer then timer:kill(); timer = nil end
    local path = mp.get_property("path")
    if path:match('%.png$') or path:match('%.jpe?g$') or path:match('%.webp$') then
        mp.set_property_number("speed", 1.0)
        timer = mp.add_timeout(${hold}, function() mp.command("playlist-next force") end)
    else
        mp.set_property_number("speed", ${vidspeed} / 100.0)
    end
end)
LUA

  # 3. Handle Fullscreen and Screen Flags
  local mpv_args=("--idle=yes" "--force-window=yes" "--no-audio" "--no-terminal" "--no-osd-bar" "--input-ipc-server=$sock" "--script=$luas" "--image-display-duration=inf")
  [ "$fs" = "1" ] && mpv_args+=(--fs)
  if [ -n "$screen" ]; then
    mpv_args+=(--screen="$screen" --fs-screen="$screen")
  fi

  # 4. Start MPV in the background and DISOWN
  mpv "${mpv_args[@]}" "$@" >/dev/null 2>&1 &
  disown

  # 5. IPC Helper Function
  _send_mpv() {
    python3 - "$sock" "$1" <<'PY'
import socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sys.argv[1])
    s.sendall((sys.argv[2] + '\n').encode())
    s.close()
except: pass
PY
  }

  # 6. Start the Background Loop and DISOWN
  (
    sleep 2 
    while pgrep -f "input-ipc-server=$sock" >/dev/null; do
      mapfile -t files < <(find "$@" -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" \) 2>/dev/null | shuf)
      
      if [ ${#files[@]} -gt 0 ]; then
        _send_mpv '{"command":["playlist-clear"]}'
        for f in "${files[@]}"; do
          _send_mpv "{\"command\":[\"loadfile\",\"$f\",\"append\"]}"
        done
        _send_mpv '{"command":["set_property","pause",false]}'
      fi
      sleep "$rescan"
    done
    rm -f "$sock" "$luas"
  ) >/dev/null 2>&1 &
  disown

  echo "[pmpv] Started in background. Use 'kmpv' to stop."
}