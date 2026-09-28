#!/bin/zsh
(( $# >= 7 )) || { echo "usage: ${0:t} ref.mkv frame w:h:x:y scale amp(0|1) out.png clip.ivf..." >&2; exit 2; }
for f in $1 ${@[7,-1]}; do [[ -f $f ]] || { echo "input not found: $f" >&2; exit 1; }; done
ref=$1; f=$2; crop=$3; sc=$4; amp=$5; out=$6; shift 6
clips=("$@")
rate=$(ffprobe -v error -show_entries stream=r_frame_rate -of csv=p=0 $ref)
POST="scale=iw*${sc}:ih*${sc}:flags=neighbor"
note=""
if [[ $amp == 1 ]]; then
  st=$(ffmpeg -hide_banner -i $ref -vf "select=eq(n\,$f),crop=$crop,format=yuv420p,signalstats,metadata=print" -f null - 2>&1)
  lo=$(echo "$st" | grep -oE 'YLOW=[0-9]+' | cut -d= -f2); hi=$(echo "$st" | grep -oE 'YHIGH=[0-9]+' | cut -d= -f2)
  lo=$(( lo > 8 ? lo - 8 : 0 )); hi=$(( hi + 8 )); gain=$(echo "219/($hi-$lo)" | bc -l)
  POST="lutyuv=y='clip((val-$lo)*$gain+16\\,16\\,235)':u=128:v=128,$POST"
  note=" (luma x$(printf %.1f $gain))"
fi
P="settb=${rate#*/}/${rate%/*},setpts=N,select=eq(n\\,$f),crop=$crop,format=yuv420p,$POST"
L="drawtext=fontsize=26:fontcolor=white:box=1:boxcolor=black@0.7:x=8:y=8:text"
in=(-i $ref); fg="[0]$P,$L='SOURCE'[v0];"
i=1; for c in $clips; do in+=(-c:v libdav1d -i $c); fg+="[$i]$P,$L='${c:t:r}'[v$i];"; i=$(( i + 1 )); done
cols=$(( i < 4 ? i : 4 )); cells=$(( (i + cols - 1) / cols * cols ))
for (( j = i; j < cells; j++ )); do fg+="[0]$P,drawbox=c=black:t=fill[v$j];"; done
pw=$(( ${crop%%:*} * sc )); r=${crop#*:}; ph=$(( ${r%%:*} * sc ))
lays=(); pads=""
for (( j = 0; j < cells; j++ )); do lays+="$(( j % cols * pw ))_$(( j / cols * ph ))"; pads+="[v$j]"; done
fg+="${pads}xstack=inputs=${cells}:layout=${(j:|:)lays}"
ffmpeg -hide_banner -v error $in -lavfi "$fg" -frames:v 1 -y $out && echo "$out$note"
