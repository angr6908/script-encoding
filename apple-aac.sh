#!/bin/zsh
if (( $# != 3 )); then
  echo "usage: ${0:t} <input.m2ts|mkv|mp4> <audio stream index, 0-based> <output.m4a>" >&2
  exit 2
fi
in=$1
idx=$2
out=$3
[[ -f $in ]] || { echo "input not found: $in" >&2; exit 1; }
[[ -e $out ]] && { echo "output exists: $out" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/aac.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
ffmpeg -hide_banner -v error -i "$in" -map 0:a:$idx -c:a pcm_s24le -y "$tmp/source.wav" || exit 1
afconvert "$tmp/source.wav" "$tmp/intermediate.caf" -d 0 -f caff --soundcheck-generate || exit 1
rm -f "$tmp/source.wav"
afconvert "$tmp/intermediate.caf" "$out" -d aac -f m4af -u pgcm 2 --soundcheck-read -b 256000 -q 127 -s 2 || exit 1
echo "done: $out"
