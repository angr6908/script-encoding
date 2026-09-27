# BDRip workflow notes (Blu-ray → AV1 + AAC MP4)

## 1. Inspect the disc
- Main feature: find the `BDMV/PLAYLIST/*.mpls` with the longest duration. A playlist can chain several clips (PlayItems), e.g. main show + bonus; each clip is a separate `BDMV/STREAM/*.m2ts`.
- `.mpls` also holds per-stream language codes and the chapter marks (`PlayListMark`). ffprobe does not read these; parse the file (marks are 45 kHz ticks, relative to the PlayItem IN time, usually 600 s).
- Disc title/credits: `BDMV/META/DL/bdmt_<lang>.xml` (`<di:name>`, `<ti:actor>`). Its thumbnails are ~640×360 — too small for cover art.
- Streams: `ffprobe -show_streams <clip>.m2ts`. Check that audio and video start at the same PTS.
- Interlacing: HD discs are often flagged 1080i but carry progressive content. Check with `ffmpeg -i clip.m2ts -frames:v 600 -vf idet -f null -`:
  - all "Progressive" → weave only (`setfield=prog`), no deinterlacer;
  - "TFF/BFF" → real interlace, deinterlace (e.g. `bwdif`).
- A lossless remux of 1080i to MP4 may report "59.94 fps" (fields stored as samples). Check frame PTS spacing before trusting it.
- Extra audio tracks: compare them (`amerge,pan=…c0-c2…,astats`). Difference = −inf dB means an exact duplicate → skip it. A different track is often commentary.
- Color: HD Blu-ray is BT.709 / limited range / chroma left even when not signaled. (UHD discs differ: BT.2020 / HDR — do not apply these tags there.)

## 2. Video encode (SVT-AV1)
```sh
ffmpeg -i <source> -an -vf fps=30000/1001,setfield=prog -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - | \
  SvtAv1EncApp -i - --preset 2 --crf 46 --input-depth 10 --tune 0 --enable-variance-boost 1 --variance-octile 6 --film-grain 8 \
  --color-primaries 1 --transfer-characteristics 1 --matrix-coefficients 1 --color-range 0 --chroma-sample-position left -b out.ivf
ffmpeg -i out.ivf -c copy -tag:v av01 out.mp4
```
- y4m carries no color info; without the color flags SVT writes "unspecified". Old encodes can be tagged at mux time (see §5) without re-encoding.
- Speed reference: preset 2 ≈ 2.4–2.7 fps at 1080p 10-bit (~27 h per 2 h 20 min). Preset 3 is ~2× faster, ~7% larger at the same CRF, −0.3 VMAF (not visible).
- Quality reference (clean CG/stage footage, grain synthesis off for scoring): CRF 46 ≈ VMAF 95.7, CRF 42 ≈ VMAF 97.
- SVT cannot resume a stopped encode. To stop a queue: kill the queue script first (otherwise it starts the next file), then its process group. Never edit a running shell script.

## 3. Audio encode (Apple Digital Masters method)
```sh
./extract_audio_apple.sh <source> <audio index, 0-based> <out.m4a>
```
Inside: `ffmpeg -map 0:a:N -c:a pcm_s24le` → `afconvert in.wav mid.caf -d 0 -f caff --soundcheck-generate` → `afconvert mid.caf out.m4a -d aac -f m4af -u pgcm 2 --soundcheck-read -b 256000 -q 127 -s 2`
- `-s 2` = VBR constrained (what Apple uses). afconvert's default is ABR (Apple TN2271, verified by test) — always pass `-s 2`.
- `-q 127` = best encoder quality. `-u pgcm 2` is undocumented; equal to the default on current macOS. Keep it to match Apple's command.
- If the source sample rate is above the target, Apple adds `-d LEF32@<rate> --src-complexity bats -r 127` to the CAF step.
- Output is deterministic (same input + macOS → bit-identical file). Expect ~10 min and ~4.7 GB temp per 2 h 20 min stereo track.
- Result: ~256 kb/s VBR, Sound Check (`iTunNORM`) and gapless (`iTunSMPB`) data included.

## 4. Metadata
- Global tags from the disc only: `title` (bdmt name), `artist` (bdmt actor); choose a `genre` (e.g. `Concert`). Leave out store/retail info and low-res cover art.
- Streams: set `language`; audio `title`/`handler_name` (e.g. `主音声` default, `副音声`).
- Chapters as an FFMETADATA file:
```
;FFMETADATA1
title=<disc title>
artist=<actor>
genre=<genre>

[CHAPTER]
TIMEBASE=1/45000
START=<mark − IN time>
END=<next mark, or OUT − IN>
title=<name>
```
- Concert chapter style: `開演`, `M1. 曲名（出演者）` (space after the period), `MC`, `終演`. Setlist lists from others may be 0- or 1-based — confirm with chapter lengths (MCs are the long ones).
- Escape `= ; # \` and newlines in FFMETADATA values.

## 5. Merge
```sh
ffmpeg -i video.mp4 -i track1.m4a -i track2.m4a -i meta.ffmeta \
 -map 0:v -map 1:a -map 2:a -map_metadata 3 -map_chapters 3 -c copy \
 -bsf:v:0 av1_metadata=color_primaries=1:transfer_characteristics=1:matrix_coefficients=1:color_range=tv:chroma_sample_position=1 \
 -metadata:s:v:0 language=jpn \
 -metadata:s:a:0 language=jpn -metadata:s:a:0 title="主音声" -metadata:s:a:0 handler_name="主音声" \
 -metadata:s:a:1 language=jpn -metadata:s:a:1 title="副音声" -metadata:s:a:1 handler_name="副音声" \
 -disposition:a:0 default -disposition:a:1 0 -metadata hd_video=2 -movflags +faststart -f mp4 .merging.mp4
python3 fix_aac_vbr_header.py .merging.mp4 track1.m4a track2.m4a
```
- ffmpeg rewrites the AAC `esds`/`btrt` bitrate fields (buffer 0, peak = average), so MediaInfo reports CBR. `fix_aac_vbr_header.py` copies the original buffer/peak/average back from the `.m4a` files. It checks every track before writing and is safe to re-run.
- The `av1_metadata` bitstream filter sets BT.709 / limited / chroma-left in the AV1 stream without re-encoding.
- Merge to a temp name, verify, then move into place. Never overwrite a file without checking what it is (`cmp` against its source).

## 6. Verify and report
- Run `mediainfo` first and build the report from its values.
- Check: chapter count, color tags, stream languages/titles/default flags, audio VBR.
- Full audio decode: `ffmpeg -i out.mp4 -map 0:a -f null -`.
- Audio copied intact: `ffmpeg -i out.mp4 -map 0:a:0 -c copy -f md5 -` equals the same for the `.m4a`.
- Report `.txt`, short layout: File / Source / Video (+ encoder command) / Audio (+ afconvert command) / Tags / Chapters.

## 7. Naming
`[YYYYMMDD][BDRip] <disc title> [1080p][AV1][10bit][AAC×N].mp4` + a `.txt` with the same name. Date = Blu-ray release date. Finder shows GB (10⁹ bytes); MediaInfo shows GiB (2³⁰).

## 8. Gotchas
- ffmpeg's `libvmaf`/`psnr` filters can mispair frames; for quality scores use the `vmaf` CLI on two y4m files (reference = exact encoder input, grain synthesis off: `-filmgrain 0 -c:v libdav1d`).
- Seeking into an `.m2ts` mid-GOP gives decode errors on the first frames; skip a few seconds after the seek point.
- zsh aborts the whole command on an unmatched glob.
- MediaInfo shows the measured bitrate instead of the 256k target when they differ by more than a few percent (short clips).
- Check free disk space before long jobs: WAV + CAF temp, `.ivf` + `.mp4` copies, `+faststart` rewrite.
