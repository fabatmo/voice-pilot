#!/bin/bash
# gate-audit.sh — what the wake-word gate missed, from /tmp/voicepilot_debug.log.
#
#   ./gate-audit.sh            everything since the app's last launch
#   ./gate-audit.sh --all      the whole log file
#   ./gate-audit.sh --watch    follow the log and print each new finding as it happens
#
# Findings:
#   MISSED PILOT   a final was dropped (gate shut) although it contains the wake word
#                  or something the recogniser makes of it — "pile of", "pilate", "pirate"
#   UNCONFIRMED    a partial opened the gate but the final did not carry "pilot"
#   TYPED COMMAND  an "action <verb>" that went in as text instead of running
#   FAILED         any command that reported a failure (open, media, SoundCloud, Orca)
#   REFUSED        delete all refused for want of a focused text field
#   UNHEARD        the microphone recorded a speech-like burst and the recogniser
#                  produced nothing for it within 2.5 s
# Plus the counts that give the denominators: opens, sends, timeouts, drops.

LOG=/tmp/voicepilot_debug.log
PILOTISH='[Pp]ilot|[Pp]ilots|[Pp]ile of|[Pp]ilate|[Pp]irate|[Pp]ylot|[Pp]ilut|[Pp]ile up|[Pp]allet|[Pp]ilo '
VERBS='send|sent|pass|delete|clear|stop|mute|write|select all|copy|paste|cut|undo|redo|new line|tab|save|close|find|open|play|pause|resume|next song|next|previous song|previous|like|unlike|go to|switch to'

classify() {
  # Reads log lines on stdin, prints findings. Keeps the last few lines so a typed
  # command can be told from an executed one (the [Gate] line follows within ~3 lines).
  awk -v pilotish="$PILOTISH" -v verbs="$VERBS" '
    function stamp(s) { return substr(s, 1, index(s, " +0000") - 1) }
    /\[Gate\] closed — dropped / {
      t = $0; sub(/.*dropped /, "", t)
      if (t ~ pilotish) print stamp($0) "  MISSED PILOT   " t
      next
    }
    /\[Gate\] asleep — dropped / {
      t = $0; sub(/.*dropped /, "", t)
      if (t ~ /[Hh]ey,? [Pp]ilot/) print stamp($0) "  MISSED WAKE-UP " t
      next
    }
    /partial opening not confirmed by the final/ {
      t = $0; sub(/.*dropped /, "", t); print stamp($0) "  UNCONFIRMED    " t; next
    }
    /\[App\] handleUtterance: / {
      t = $0; sub(/.*handleUtterance: /, "", t)
      if (t ~ ("[Aa]ction,? (" verbs ")")) { pending = t; pendingAt = stamp($0); pendingN = NR }
      next
    }
    /\[Gate\] "action / { pending = ""; next }
    /\[TC\] typeText called/ {
      if (pending != "" && NR - pendingN <= 3) { print pendingAt "  TYPED COMMAND  " pending; pending = "" }
      next
    }
    /\[Audio\] .*NO recogniser output/ { print stamp($0) "  UNHEARD        " substr($0, index($0, "[")); next }
    /FAILED/ { print stamp($0) "  FAILED         " substr($0, index($0, "[")); next }
    /delete all refused/ { print stamp($0) "  REFUSED        " substr($0, index($0, "[")); next }
  '
}

counts() {
  printf '%-14s %s\n' \
    "opened"   "$(grep -c '\[Gate\] opened by' <<<"$1")" \
    "sent"     "$(grep -c 'closed after send' <<<"$1")" \
    "timed out" "$(grep -c 's silence — say' <<<"$1")" \
    "dropped"  "$(grep -c '\[Gate\] closed — dropped' <<<"$1")" \
    "commands" "$(grep -c '\[Gate\] "action ' <<<"$1")"
}

case "${1:-}" in
  --watch)
    echo "watching $LOG — findings appear as they happen (ctrl-C to stop)"
    tail -n 0 -F "$LOG" | classify
    ;;
  --all)
    text=$(cat "$LOG")
    echo "== whole log =="; counts "$text"; echo "-- findings --"; classify <<<"$text"
    ;;
  *)
    n=$(grep -n 'applicationDidFinishLaunching' "$LOG" | tail -1 | cut -d: -f1)
    text=$(tail -n +"${n:-1}" "$LOG")
    echo "== since the last launch ($(sed -n "${n}p" "$LOG" | cut -c1-30)) =="
    counts "$text"; echo "-- findings --"; classify <<<"$text"
    ;;
esac
