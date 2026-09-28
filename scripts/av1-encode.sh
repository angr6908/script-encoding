#!/bin/zsh
zparseopts -D -E c:=oc p:=op r:=or o:=oo n=on
crf=${oc[2]:-46}; preset=${op[2]:-2}; fps=${or[2]:-30000/1001}; noaudio=${#on}
(( $# )) || { echo "usage: ${0:t} [-c crf] [-p preset] [-r fps] [-o outdir] [-n] file..." >&2; exit 2; }
for f in $@; do [[ -f $f ]] || { echo "input not found: $f" >&2; exit 1; }; done
if [[ $fps == */* ]]; then num=${fps%/*}; den=${fps#*/}; else num=$fps; den=1; fi
files=(${@:A})
dir=${${oo[2]:-${files[1]:h}}:A}
mkdir -p $dir || exit 1
log=$dir/av1-encode-crf${crf}-p${preset}.log
base=(--preset $preset --crf $crf --input-depth 10 --tune 0 --enable-variance-boost 1 --variance-octile 6 --film-grain 8)
typeset -A PRI=(bt709 1 bt470m 4 bt470bg 5 smpte170m 6 smpte240m 7 bt2020 9)
typeset -A TRC=(bt709 1 bt470m 4 bt470bg 5 smpte170m 6 smpte240m 7 bt2020-10 14 smpte2084 16 arib-std-b67 18)
typeset -A MAT=(bt709 1 fcc 4 bt470bg 5 smpte170m 6 smpte240m 7 bt2020nc 9)
mp4audio=(aac alac ac3 eac3 mp3 opus flac)

tot=(); durs=()
for f in $files; do
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $f)
  durs+=$d
  tot+=$(printf "%.0f" $(( d * num * 1.0 / den )))
done

hm() { printf "%dh%02dm" $(( $1 / 3600 )) $(( $1 % 3600 / 60 )); }
ts() { date '+%F %T'; }

colorflags() {
  local -A s
  local k v
  while IFS='=' read -r k v; do s[$k]=$v; done < <(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries,color_transfer,color_space,color_range,chroma_location,height -of default=nw=1 $1)
  local h=${s[height]:-1080} dp=1 dt=1 dm=1
  if (( h < 720 )); then
    if (( h == 576 )); then dp=5; dt=6; dm=5; else dp=6; dt=6; dm=6; fi
  fi
  local cp=${PRI[${s[color_primaries]}]:-$dp} ct=${TRC[${s[color_transfer]}]:-$dt} cm=${MAT[${s[color_space]}]:-$dm}
  local cr=0; [[ ${s[color_range]} == pc ]] && cr=1
  local cs=left; [[ ${s[chroma_location]} == topleft ]] && cs=topleft
  echo "--color-primaries $cp --transfer-characteristics $ct --matrix-coefficients $cm --color-range $cr --chroma-sample-position $cs"
}

monitor() {
  local name=$1 out=$2 start=$3 total=$4 rest=$5
  while sleep 300; do
    local fr=$(tail -n 20 $out.progress 2>/dev/null | grep '^frame=' | tail -1 | cut -d= -f2)
    [[ -z $fr || $fr -eq 0 ]] && continue
    local now=$(date +%s)
    local el=$(( now - start ))
    local fs=$(( fr * 1.0 / el ))
    local left=$(( total - fr ))
    local eta=$(printf "%.0f" $(( left / fs )))
    local etaall=$(printf "%.0f" $(( (left + rest) / fs )))
    printf "%s  %s  frame %d/%d (%.1f%%)  %.2f fps  elapsed %s  |  file ETA %s (~%s)  |  all ETA %s (~%s)\n" \
      "$(ts)" $name $fr $total $(( fr * 100.0 / total )) $fs $(hm $el) \
      $(hm $eta) "$(date -r $(( now + eta )) '+%m-%d %H:%M')" \
      $(hm $etaall) "$(date -r $(( now + etaall )) '+%m-%d %H:%M')" >> $log
  done
}

need=0; maxd=0; for d in $durs; do need=$(( need + d * 500000 )); (( d > maxd )) && maxd=$d; done
need=$(printf "%.0f" $(( need + maxd * 500000 )))
free=$(( $(df -k $dir | tail -1 | awk '{print $4}') * 1024 ))
echo "$(ts)  queue: ${files[@]:t}  frames: ${tot[*]}  preset $preset crf $crf fps $fps  pid $$ pgid $(ps -o pgid= -p $$ | tr -d ' ')" >> $log
if (( free < need )); then
  echo "$(ts)  abort: free $(( free / 1000000000 )) GB < estimated need $(( need / 1000000000 )) GB" >> $log
  exit 1
fi

for i in {1..${#files}}; do
  f=${files[$i]}
  out=${${oo[2]:+$dir}:-${f:h}}/${f:t:r}_av1_crf${crf}_p${preset}
  if [[ -f $out.mp4 || -f $out.mkv ]]; then echo "$(ts)  skip ${f:t} (output exists)" >> $log; continue; fi
  rest=0; for t in ${tot[$(( i + 1 )),-1]}; do rest=$(( rest + t )); done
  svt=($base ${=$(colorflags $f)})
  acodecs=(); (( noaudio )) || acodecs=($(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 $f))
  ext=mp4; for a in $acodecs; do (( ${mp4audio[(Ie)$a]} )) || ext=mkv; done
  start=$(date +%s)
  echo "$(ts)  start ${f:t} -> ${out:t}.$ext  audio: ${acodecs:-none}  svt: ${svt[*]}" >> $log
  monitor ${f:t} $out $start ${tot[$i]} $rest &
  mpid=$!
  ffmpeg -hide_banner -v error -stats_period 30 -progress $out.progress -i $f -an -vf fps=$fps,setfield=prog -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 2>$out.ffmpeg.log | \
    SvtAv1EncApp -i - $svt -b $out.ivf 2>$out.svt.log
  st=(${pipestatus[@]})
  kill $mpid 2>/dev/null
  res=failed; chk=""
  if (( st[1] == 0 && st[2] == 0 )); then
    tmp=$out.tmp.$ext
    mux=(-map 0:v:0 -c copy); (( noaudio )) || mux=(-map 0:v:0 -map '1:a?' -c copy)
    [[ $ext == mp4 ]] && mux+=(-tag:v av01 -movflags +faststart)
    if ffmpeg -hide_banner -v error -i $out.ivf -i $f $mux -y $tmp 2>>$out.ffmpeg.log && [[ -s $tmp ]]; then
      enc=$(tail -n 20 $out.progress | grep '^frame=' | tail -1 | cut -d= -f2)
      got=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $tmp)
      if [[ $got == $enc ]]; then
        mv $tmp $out.$ext && rm -f $out.ivf && res=$out.$ext && chk="verify ok ($got frames)"
      else
        chk="VERIFY FAILED: $got frames in output, $enc encoded; kept $tmp and ${out:t}.ivf"
      fi
    fi
  fi
  el=$(( $(date +%s) - start ))
  echo "$(ts)  end ${f:t}  ffmpeg=${st[1]} svt=${st[2]}  elapsed $(hm $el)  $(printf '%.2f' $(( tot[$i] * 1.0 / el ))) fps  -> ${res:t} $(stat -f %z $res 2>/dev/null) bytes  $chk" >> $log
done
echo "$(ts)  all done" >> $log
