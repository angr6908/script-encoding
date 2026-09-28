#!/bin/zsh
(( $# >= 2 )) || { echo "usage: ${0:t} source start(sec|hh:mm:ss) [dur=5] [out.mkv] [fps=30000/1001]" >&2; exit 2; }
[[ -f $1 ]] || { echo "input not found: $1" >&2; exit 1; }
src=$1; start=$2; dur=${3:-5}; fps=${5:-30000/1001}
[[ $start == *:* ]] && start=$(echo $start | awk -F: '{t=0; for(i=1;i<=NF;i++) t=t*60+$i; print t}')
out=${4:-${src:r}_clip_${start}s.mkv}
pre=$(( start > 20 ? 20 : start ))
ffmpeg -hide_banner -v error -ss $(( start - pre )) -i $src -ss $pre -t $dur -an -vf fps=$fps,setfield=prog -c:v ffv1 -level 3 -y $out 2>/dev/null || exit 1
echo "$out  $(ffprobe -v error -count_frames -show_entries stream=nb_read_frames,r_frame_rate -of csv=p=0 $out) (fps, frames)"
