#!/bin/zsh
#
# AVIF converter for a macOS Shortcuts / Quick Action "Run Shell Script" action.
#
#   Automation : Folder ~/Downloads, "Files and Folders" -> "Is Modified"  (fires when a file is added)
#   Action     : Shell: zsh, "Pass input: as arguments", this script pasted as the body.
#
# Paste it as-is: it is self-contained, needs no companion file, no $0, and no arguments.
# It converts every PNG in ~/Downloads to AVIF and deletes each PNG once its .avif is in
# place. It runs in the foreground and exits as soon as the folder is clean, so it can be
# interrupted at any point without losing data.
#
# One run at a time: overlapping triggers (a burst of files) coordinate through a lock, so
# the same PNG is never encoded twice, and a trigger that arrives while a run is finishing
# waits for that run rather than starting a second converter.
#
# Encoding settings are unchanged from the original script (-q 60 -s 0 -d 10 -j all).
emulate -L zsh
setopt no_hup null_glob nocaseglob
zmodload zsh/datetime 2>/dev/null   # EPOCHREALTIME: sub-second clock, costs no fork
zmodload zsh/stat 2>/dev/null       # zstat: size/mtime, costs no fork

WATCH="$HOME/Downloads"                                 # folder to scan; arguments are not needed
RUN="$HOME/Library/Application Support/avif-convert"    # scratch/state, never a code dependency
LOCKDIR="$RUN/lock.d"                                   # mkdir is the atomic test: one winner
PIDFILE="$RUN/lock.pid"                                 # who holds it, used to tell live from stale
AVIF="/opt/homebrew/bin/avifenc"                        # brew install libavif
POLL=0.15         # s  scan interval, and how soon a settled file is picked up
QUIET=0.65        # s  a file whose size+mtime have not moved for this long has no writer left
MAXWAIT=10        # s  how long a trigger waits for a run in flight before giving up on it
MAXRUN=120        # s  hard stop for one run, in case a download stalls forever
BIG=26214400      # B  above this size, also require that no process holds the file open
MAXBACKOFF=300    # s  cap on the retry delay for files that keep failing

mkdir -p "$RUN" 2>/dev/null
[[ -x "$AVIF" ]] || exit 127

now() { print -r -- "${EPOCHREALTIME:-$(date +%s)}"; }   # float seconds; forks only if the module is missing
readpid() { local p=""; [[ -s "$1" ]] && p="$(<"$1")" 2>/dev/null; print -r -- "${p//[^0-9]/}"; }

# ------------------------------------------------------------------- locking
# The holder writes its pid next to the lock, so a lock left behind by a killed run can be
# told apart from a run that is genuinely busy. Ownership is checked with ps because a pid
# alone can be recycled by an unrelated process, which would wedge the folder forever.
# Returning non-zero means "someone else has it" and the caller must not convert.
holder_is_ours() {
    local pid="$1" cmd
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cmd="$(ps -p "$pid" -o command= 2>/dev/null)" || return 1
    [[ "$cmd" == *"$LOCKDIR"* || "$cmd" == *"$AVIF"* || "$cmd" == *"zsh"* ]]
}

acquire() {
    # Fast path: claim it atomically.
    mkdir "$LOCKDIR" 2>/dev/null && print -r -- "$$" >"$PIDFILE" && return 0
    # Taken. Normally the holder finishes quickly, so keep retrying the atomic claim: that
    # costs one mkdir and reacts the moment the lock is released, without any extra latency.
    local i pid
    for i in {1..$(( MAXWAIT * 10 ))}; do
        sleep 0.1
        pid="$(readpid "$PIDFILE")"
        if ! holder_is_ours "$pid"; then
            # The holder is gone but its lock dir survived: it was killed. Retire it, and
            # only that one, then try again. An encode interrupted here is lost work, not
            # lost data: the png is still on disk for this run to pick up.
            [[ -n "$pid" ]] && rmdir "$LOCKDIR" 2>/dev/null && rm -f -- "$PIDFILE"
        fi
        mkdir "$LOCKDIR" 2>/dev/null && print -r -- "$$" >"$PIDFILE" && return 0
    done
    return 1
}
if ! acquire; then
    # A run is in flight. It rescans the folder every pass, so it will see whatever arrived;
    # leaving now is correct, and waiting here is what keeps two converters from racing.
    exit 0
fi
# Releasing the lock is only safe if the run also stops, which is why TERM exits.
cleanup() { rm -f -- "$PIDFILE"; rmdir "$LOCKDIR" 2>/dev/null }
trap 'cleanup; exit 143' INT TERM HUP
trap 'cleanup' EXIT

# lsof needs -a to AND its filters; keep only the options this build accepts.
typeset -a LSOF_OPTS
/usr/sbin/lsof -a -p $$ -d cwd >/dev/null 2>&1 && LSOF_OPTS=(-a) || LSOF_OPTS=()

# ------------------------------------------------------------------- helpers
stat_sz() { local -a s; [[ -e "$1" ]] && zstat -A s +size -- "$1" 2>/dev/null && print -r -- "$s[1]"; }
# -F '%s.%9.' returns float seconds and keeps the sub-second part; bare +mtime truncates it.
stat_mt() { local -a s; [[ -e "$1" ]] && zstat -A s -F '%s.%9.' +mtime -- "$1" 2>/dev/null && print -r -- "$s[1]"; }

# A PNG ends with the IEND chunk, so a file that has stopped growing without one is a
# stalled download, not a finished image. no_multibyte makes the slice byte-wise, because
# the trailing CRC bytes are not valid UTF-8.
is_complete_png() {
    local t
    setopt localoptions no_multibyte
    t="$(tail -c 8 -- "$1" 2>/dev/null)" || return 1
    [[ "${t[1,4]}" == IEND ]]
}

# Cheap candidate test, builtins only: it runs for every png on every pass.
is_candidate() {
    local f="$1" sz
    [[ -f "$f" ]] || return 1
    [[ "${f:e:l}" == png ]] || return 1
    [[ -e "${f:r}.avif" ]] && return 1        # an .avif beside it means already done
    sz="$(stat_sz "$f")"
    (( ${sz:--1} > 0 )) || return 1
    return 0
}

# Encode to a private name, then a single rename into place: no reader ever sees a
# half-written .avif, and the .png is removed only after that rename succeeded.
convert() {
    local f="$1" base out tmp rc=0
    is_candidate "$f" || return 0                 # re-check: an .avif may have landed meanwhile
    is_complete_png "$f" || return 1              # never encode a half-written file
    base="${f:h}/${f:t:r}"; out="$base.avif"; tmp="$base.avif.part.$$"
    "$AVIF" -q 60 -s 0 -d 10 -j all --no-overwrite -o "$tmp" -- "$f" >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )) || [[ ! -s "$tmp" ]]; then
        rm -f -- "$tmp"; return 1
    fi
    if [[ -e "$out" ]]; then
        rm -f -- "$tmp"; return 0                 # keep whatever is already published
    fi
    if mv -f -- "$tmp" "$out"; then
        rm -f -- "$f"
    else
        rm -f -- "$tmp"; return 1
    fi
    return 0
}

# Quiet-window bookkeeping. Nothing in this loop blocks: each pass only samples, so the
# wait for one file overlaps the wait for every other file instead of queueing behind it.
typeset -A fails nexttry seen_size seen_mt seen_at

# One pass over the folder. Sets REPLY to 1 when there is still something worth waiting for.
sweep() {
    local f s m since pending=0
    # Newest first, so a burst drains in the order it arrived.
    for f in "$WATCH"/*.png(.Om); do
        is_candidate "$f" || continue
        (( ${nexttry[$f]:-0} > $(now) )) && continue        # backing off after a failure
        s="$(stat_sz "$f")"; m="$(stat_mt "$f")"
        [[ -n "$s" && -n "$m" ]] || continue
        if [[ "${seen_size[$f]}" == "$s" && "${seen_mt[$f]}" == "$m" ]]; then
            since="${seen_at[$f]}"
            (( m > since )) && since="$m"                   # the later of: first seen, last written
            if (( $(now) - since >= QUIET )); then
                # Settled. A settled file that is not a complete PNG is a stalled download:
                # leave it alone and do not hold the run open for it.
                is_complete_png "$f" || continue
                # Big files: a slow writer can still hold a lot in its buffer with nothing on disk.
                if (( s >= BIG )) && /usr/sbin/lsof ${LSOF_OPTS[@]} -- "$f" >/dev/null 2>&1; then
                    pending=1; continue
                fi
                if convert "$f"; then
                    unset "fails[$f]" "nexttry[$f]" "seen_size[$f]" "seen_mt[$f]" "seen_at[$f]"
                else
                    local n=$(( ${fails[$f]:-0} + 1 )); fails[$f]=$n
                    local backoff=$(( 2 ** n )); (( backoff > MAXBACKOFF )) && backoff=$MAXBACKOFF
                    nexttry[$f]=$(( $(now) + backoff ))
                    unset "seen_at[$f]"                     # a retry gets a fresh quiet window
                fi
            else
                pending=1                                   # settled soon, keep waiting for it
            fi
        else
            # First sight, or the writer moved it: (re)start the window and look again.
            seen_size[$f]="$s"; seen_mt[$f]="$m"; seen_at[$f]="$(now)"
            pending=1
        fi
    done
    REPLY=$pending
}

# ------------------------------------------------------------------ main run
deadline=$(( $(now) + MAXRUN ))
while :; do
    sweep
    # Leftovers from a run that was killed mid-encode (never from this one).
    for f in "$WATCH"/*.avif.part.*(Nm+60); do rm -f -- "$f"; done
    (( REPLY )) || break                     # folder is clean
    (( $(now) < deadline )) || break         # something is stuck; the next trigger resumes it
    sleep "$POLL"
done
exit 0
