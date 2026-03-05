mic_record() {
  local mode="stt"
  local out_path=""
  local usage="Usage: mic_record [-m|--mode raw|stt|ident] [OUT.wav]"

  # ---- parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mode)
        shift
        [[ -z "${1:-}" ]] && { echo "$usage" >&2; return 2; }
        mode="$1"
        shift
        ;;
      -h|--help)
        echo "$usage"
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "mic_record: unknown option: $1" >&2
        echo "$usage" >&2
        return 2
        ;;
      *)
        if [[ -n "$out_path" ]]; then
          echo "mic_record: unexpected extra arg: $1" >&2
          echo "$usage" >&2
          return 2
        fi
        out_path="$1"
        shift
        ;;
    esac
  done

  case "$mode" in
    raw|stt|ident) : ;;
    *)
      echo "mic_record: invalid mode: $mode (expected raw|stt|ident)" >&2
      return 2
      ;;
  esac

  # ---- deps
  command -v arecord >/dev/null 2>&1 || { echo "mic_record: arecord not found" >&2; return 127; }
  if [[ "$mode" != "raw" ]]; then
    command -v ffmpeg >/dev/null 2>&1 || { echo "mic_record: ffmpeg not found (required for mode=$mode)" >&2; return 127; }
  fi

  # ---- temp files
  local raw_tmp final_tmp are_err
  raw_tmp="$(mktemp -t mic_record_raw_XXXXXXXX.wav)" || return $?
  are_err="$(mktemp -t mic_record_arecord_err_XXXXXXXX.txt)" || { rm -f "$raw_tmp"; return 1; }

  if [[ -n "$out_path" ]]; then
    final_tmp="$out_path"
  else
    final_tmp="$(mktemp -t mic_record_${mode}_XXXXXXXX.wav)" || { rm -f "$raw_tmp" "$are_err"; return 1; }
  fi

  _mic_record_cleanup() {
    rm -f "$raw_tmp" "$final_tmp" "$are_err" 2>/dev/null
  }

  # ---- start recording (capture stderr so we can suppress expected SIGINT noise)
  arecord -q -f cd "$raw_tmp" 2>"$are_err" &
  local rec_pid=$!

  trap 'kill -INT "$rec_pid" 2>/dev/null; wait "$rec_pid" 2>/dev/null; _mic_record_cleanup; return 130' INT TERM

  # ---- DRY mode message
  declare -A MODE_MSG=(
    [raw]="raw audio"
    [stt]="accurate speech recognition"
    [ident]="speaker identity / voice cloning"
  )

  echo "Recording (${MODE_MSG[$mode]})…"
  echo "Press Enter when done, Escape to cancel."

  # ---- wait for Enter (accept) or Escape (cancel); ignore all other keys
  local key=""
  while true; do
    key=""
    IFS= read -rsn1 key

    # Enter often yields empty string with -n1; treat that as accept.
    if [[ -z "$key" ]]; then
      break
    fi

    # Escape cancels.
    if [[ "$key" == $'\e' ]]; then
      kill -INT "$rec_pid" 2>/dev/null
      wait "$rec_pid" 2>/dev/null
      trap - INT TERM
      _mic_record_cleanup
      return 130
    fi

    # Any other key: ignore and keep recording.
  done

  # ---- stop recording cleanly
  kill -INT "$rec_pid" 2>/dev/null
  wait "$rec_pid" 2>/dev/null
  local arec_rc=$?

  trap - INT TERM

  # ---- suppress the expected arecord noise when we intentionally interrupt it
  if [[ $arec_rc -ne 0 ]]; then
    if grep -q "Interrupted system call" "$are_err"; then
      :  # expected; ignore
    else
      cat "$are_err" >&2
      echo "mic_record: arecord failed (rc=$arec_rc)" >&2
      _mic_record_cleanup
      return "$arec_rc"
    fi
  fi

  # ---- mode handling
  if [[ "$mode" == "raw" ]]; then
    if ! mv -f "$raw_tmp" "$final_tmp" 2>/dev/null; then
      if ! cp -f "$raw_tmp" "$final_tmp"; then
        cat "$are_err" >&2
        echo "mic_record: failed to write output: $final_tmp" >&2
        _mic_record_cleanup
        return 1
      fi
      rm -f "$raw_tmp"
    fi
    rm -f "$are_err"
    echo "$final_tmp"
    return 0
  fi

  # ---- stt / ident post-processing
  local ar="16000"
  local hp="80"
  local lp="8000"
  if [[ "$mode" == "ident" ]]; then
    ar="22050"
    lp="9000"
  fi

  if ! ffmpeg -hide_banner -loglevel error -y \
      -i "$raw_tmp" \
      -ac 1 -ar "$ar" \
      -af "highpass=f=${hp},lowpass=f=${lp},alimiter=limit=0.95" \
      "$final_tmp"
  then
    cat "$are_err" >&2
    echo "mic_record: ffmpeg post-process failed (mode=$mode)" >&2
    _mic_record_cleanup
    return 1
  fi

  rm -f "$raw_tmp" "$are_err"
  echo "$final_tmp"
  return 0
}
