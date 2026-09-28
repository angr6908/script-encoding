# BDRip workflow notes (Blu-ray → AV1 + AAC MP4)

Video encoding (recipe, source checks, CRF/preset, running jobs, pitfalls) is in [av1.md](av1.md). This file covers the disc-specific steps.

## 1. Inspect the disc
- Main feature: find the `BDMV/PLAYLIST/*.mpls` with the longest duration. A playlist can chain several clips (PlayItems), e.g. main show + bonus; each clip is a separate `BDMV/STREAM/*.m2ts`.
- `.mpls` also holds per-stream language codes and the chapter marks (`PlayListMark`). ffprobe does not read these; parse the file (marks are 45 kHz ticks, relative to the PlayItem IN time, usually 600 s).
- Disc title/credits: `BDMV/META/DL/bdmt_<lang>.xml` (`<di:name>`, `<ti:actor>`). Its thumbnails are ~640×360 — too small for cover art.
- Streams: `ffprobe -show_streams <clip>.m2ts`. Check that audio and video start at the same PTS.
- Frame rate / interlacing: HD discs are often flagged 1080i but carry progressive content. Check per [av1.md → Source checks](av1.md#source-checks).
- Extra audio tracks: compare them (`amerge,pan=…c0-c2…,astats`). Difference = −inf dB means an exact duplicate → skip it. A different track is often commentary.
- Color: HD Blu-ray is BT.709 / limited range / chroma left even when not signaled. (UHD discs differ: BT.2020 / HDR — do not apply these tags there.)

## 2. Video encode (SVT-AV1)
```sh
scripts/av1-encode.sh -n -o <workdir> <source>
```
- `-n` = video only; audio is encoded in §3 and merged in §5. Output: `<workdir>/<source name>_av1_crf46_p2.mp4`, already tagged BT.709 / limited / chroma-left for untagged HD.
- Recipe, speed and quality references, choosing CRF/preset, stopping a job: [av1.md](av1.md).

## 3. Audio encode (Apple Digital Masters method)
```sh
scripts/apple-aac.sh <source> <audio index, 0-based> <out.m4a>
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
 -metadata:s:v:0 language=jpn \
 -metadata:s:a:0 language=jpn -metadata:s:a:0 title="主音声" -metadata:s:a:0 handler_name="主音声" \
 -metadata:s:a:1 language=jpn -metadata:s:a:1 title="副音声" -metadata:s:a:1 handler_name="副音声" \
 -disposition:a:0 default -disposition:a:1 0 -metadata hd_video=2 -movflags +faststart -f mp4 .merging.mp4
python3 scripts/ffmpeg-fix-aac-vbr-header.py .merging.mp4 track1.m4a track2.m4a
```
- ffmpeg rewrites the AAC `esds`/`btrt` bitrate fields (buffer 0, peak = average), so MediaInfo reports CBR. `ffmpeg-fix-aac-vbr-header.py` copies the original buffer/peak/average back from the `.m4a` files. It checks every track before writing and is safe to re-run.
- Video from `av1-encode.sh` already carries color tags. For an older untagged encode, add the `av1_metadata` filter from [av1.md](av1.md#scripts) to this command.
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
Video, metric and zsh pitfalls: [av1.md → Pitfalls](av1.md#pitfalls).
- MediaInfo shows the measured bitrate instead of the 256k target when they differ by more than a few percent (short clips).
- Check free disk space before long jobs: WAV + CAF temp, `.ivf` + `.mp4` copies, `+faststart` rewrite.
