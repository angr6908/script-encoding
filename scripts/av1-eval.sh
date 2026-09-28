#!/bin/zsh
zmodload zsh/datetime
(( $# >= 4 )) || { echo "usage: ${0:t} ref.mkv name preset crf [svt flags...]" >&2; exit 2; }
[[ -f $1 ]] || { echo "input not found: $1" >&2; exit 1; }
ref=$1; name=$2; preset=$3; crf=$4; shift 4
flags=("$@"); (( ${#flags} )) || flags=(--tune 0 --enable-variance-boost 1 --variance-octile 6 --film-grain 8)
rate=$(ffprobe -v error -show_entries stream=r_frame_rate -of csv=p=0 $ref)
n=$(ffprobe -v error -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $ref)
F="settb=${rate#*/}/${rate%/*},setpts=N,format=yuv420p10le"
t0=$EPOCHREALTIME
ffmpeg -hide_banner -v error -i $ref -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - | \
  SvtAv1EncApp -i - --preset $preset --crf $crf --input-depth 10 $flags -b $name.ivf >/dev/null 2>$name.svt.log || { echo "encode failed, see $name.svt.log"; exit 1; }
t=$(( EPOCHREALTIME - t0 ))
kb=$(( $(stat -f %z $name.ivf) * 8.0 / 1000 / (n * ${rate#*/}.0 / ${rate%/*}) ))
ffmpeg -hide_banner -v error -filmgrain 0 -c:v libdav1d -i $name.ivf -i $ref -lavfi "[0]${F}[d];[1]${F}[r];[d][r]libvmaf=feature=name=cambi:n_threads=8:log_fmt=csv:log_path=$name.ng.csv" -f null - 2>/dev/null
ffmpeg -hide_banner -v error -c:v libdav1d -i $name.ivf -i $ref -lavfi "[0]${F}[d];[1]${F}[r];[d][r]libvmaf=feature=name=cambi:n_threads=8:log_fmt=csv:log_path=$name.g.csv" -f null - 2>/dev/null
col() { awk -F, -v c=$2 'NR==1{for(i=1;i<=NF;i++)if($i==c)k=i;next}{print $k}' $1; }
v=$(col $name.ng.csv vmaf | sort -n | awk '{a[NR]=$1;s+=$1}END{printf "%.2f / %.2f", s/NR, a[1]}')
cg=$(col $name.g.csv cambi | awk '{s+=$1;if($1>m)m=$1}END{printf "%.2f / %.2f", s/NR, m}')
cng=$(col $name.ng.csv cambi | awk '{s+=$1;if($1>m)m=$1}END{printf "%.2f / %.2f", s/NR, m}')
rm -f $name.ng.csv $name.g.csv
printf "%s | p%s crf%s | %.0f kbps | %.1fs (%.2f fps) | VMAF mean/worst %s | CAMBI viewed %s | CAMBI no-grain %s\n" $name $preset $crf $kb $t $(( n / t )) "$v" "$cg" "$cng"
