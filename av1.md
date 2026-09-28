# AV1 video encoding (SVT-AV1)

## Recipe

```sh
ffmpeg -i in.mp4 -an -vf fps=30000/1001,setfield=prog -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - | \
SvtAv1EncApp -i - --preset 2 --crf 46 --input-depth 10 \
  --tune 0 --enable-variance-boost 1 --variance-octile 6 --film-grain 8 \
  --color-primaries 1 --transfer-characteristics 1 --matrix-coefficients 1 --color-range 0 --chroma-sample-position left \
  -b out.ivf
ffmpeg -i out.ivf -c copy -tag:v av01 -movflags +faststart out.mp4
```

- **`fps=30000/1001`:** the target is half the source's flagged frame rate, and 30000/1001 is half of 59.94. For other sources, pass half their flagged rate (for example `-r 25` for a source flagged 50 fps).
- **`setfield=prog`:** marks each frame as progressive, so the two stored halves (fields) are put back together as-is. This is correct only when both halves come from the same moment; see [Source checks](#source-checks). It adds no deinterlace blur.
- **Color flags:** y4m (the raw format piped into SvtAv1EncApp) carries no color information, so without these flags SVT writes "unspecified". The values shown are BT.709, limited range, chroma left: standard for HD. `av1-encode.sh` uses the source's own tags when it has them.
- **CRF 46 at preset 2** is the safe choice. CRF 48 is the highest before visible artifacts; they start at CRF 49.

## Scripts

| Script | Usage | What it does |
|---|---|---|
| `scripts/av1-encode.sh` | `[-c 46] [-p 2] [-r 30000/1001] [-o outdir] [-n] file...` | Encodes files one after another with the recipe above. Output is `<name>_av1_crfX_pY.mp4`, or `.mkv` if the audio codec isn't widely supported in MP4. It goes next to each source, or into `-o`. `-n` gives video only; otherwise the source audio is copied. Details below. |
| `scripts/av1-testclip.sh` | `source start [dur=5] [out.mkv] [fps]` | Extracts a lossless FFV1 test clip. `start` is in seconds or hh:mm:ss. Decoding starts 20 s early. |
| `scripts/av1-eval.sh` | `clip.mkv name preset crf [svt flags]` | Encodes a test clip and prints bitrate, speed, VMAF (average and worst frame, grain off), and CAMBI with and without grain. |
| `scripts/av1-crops.sh` | `clip.mkv frame w:h:x:y scale amp out.png a.ivf...` | Builds an image grid of the source next to each encode. `amp=1` stretches the brightness range so banding and blocking become visible. |

Details of `av1-encode.sh`:
- **Color tags:** taken from the source; untagged HD gets BT.709.
- **Log:** an ETA line every 5 minutes, plus the script's PID and process group.
- **Safety checks:** free disk space before starting; the output's frame count is verified before the temp file is renamed.
- **Reruns:** files that are already done are skipped.
- **MP4 output** is written with `+faststart`.
- **Lossless source audio** (PCM, TrueHD): run with `-n`, encode AAC with `scripts/apple-aac.sh`, and merge as in [bdrip.md](bdrip.md) §3–5.

**Long jobs:**
- **Run detached:** `nohup caffeinate -ims scripts/av1-encode.sh a.mp4 b.mp4 >/dev/null 2>&1 &` keeps running after the terminal closes, and the Mac won't sleep.
- **Stop:** `kill <pid>` first (otherwise the script starts the next file), then `kill -- -<pgid>`. Both numbers are in the log.
- SVT can't resume a stopped encode, and never edit a running script.

**Tagging an old, untagged encode** without re-encoding:
```sh
ffmpeg -i old.mp4 -map 0 -c copy -bsf:v av1_metadata=color_primaries=1:transfer_characteristics=1:matrix_coefficients=1:color_range=tv:chroma_sample_position=1 -tag:v av01 -movflags +faststart new.mp4
```

## Source checks

- **Frame rate:** compare `nb_frames` (from `ffprobe`) against the number of frames that actually decode (`ffmpeg -i in -f null -`). A 1080i disc or remux flagged 59.94 is often 29.97p stored as separate half-frames (fields). The tell: packet sizes alternate large/small and decoded frames are 1/29.97 s apart.
- **Interlacing:** `ffmpeg -i in -frames:v 600 -vf idet -f null -`.
  - All "Progressive": both halves come from the same moment. Use `setfield=prog`, with no deinterlace filter.
  - "TFF"/"BFF": true interlaced. Deinterlace, for example with `bwdif`.
- **Color:** check the source's color tags. HDR sources (transfer smpte2084 or arib-std-b67) also need `--mastering-display` and `--content-light`, which `av1-encode.sh` doesn't handle.

## Choosing CRF and preset

1. **Extract 1–3 hard clips** with `av1-testclip.sh`: dark gradients, faces or hair, fog, motion.
2. **Sweep CRF** with `av1-eval.sh`, then compare by eye with `av1-crops.sh`. The best CRF is the highest one before new artifacts appear: blotches in flat areas, halos along hair.
3. **Pick the preset** from the time budget (see speeds below), then run `av1-encode.sh`.
4. **Verify the output** with `mediainfo` or `ffprobe`: color tags, duration, audio.

## Findings

These are from a 5-second dark CG concert clip at 1080p, 29.97 fps. VMAF is measured with grain off. CAMBI is Netflix's banding score: 0 means none, 5 or more is visible. The source clip itself scored 4.7 on average and 11 on its worst frame.

**Anti-banding flags.** Found by removing one parameter at a time, at preset 4, CRF 35:

| Parameter | Verdict | Evidence |
|---|---|---|
| `--film-grain 8` | Keep | Removing it: CAMBI goes from 0.00 / 0.18 to 1.88 / 5.71 (average / worst frame) |
| `--input-depth 10` | Keep | Encoding in 8-bit: worst frame 10.3 |
| `--enable-variance-boost 1 --variance-octile 6` | Keep | With grain off, CAMBI goes from 1.88 to 3.12, even at a lower CRF with more bits |
| `--tune 0` | Keep | CAMBI goes from 1.88 to 3.11 at the same bitrate. The default is `1` (PSNR) |
| `--luminance-qp-bias`, `--qp-scale-compress-strength`, `--enable-dlf 2` | Dropped | No banding benefit, or no better than just lowering the CRF |
| `--variance-boost-strength 2`, `--film-grain-denoise 0` | Dropped | Already the defaults |

**Preset and CRF:**

| Setting | Bitrate | VMAF | Speed |
|---|---|---|---|
| P4 / P3 / P2 at CRF 45 | 2874 / 2881 / 2699 kbps | 95.4 / 95.8 / 96.1 | 7.7 / 5.6 / 3.3 fps |
| P2 at CRF 40 / 45 / 46 / 48 / 50 | 3729 / 2699 / 2521 / 2262 / 1984 kbps | 97.7 / 96.1 / 95.7 / 94.9 / 94.0 | ~3.3 fps |

- **CRF steps:** each +1 CRF saves about 5–7% in size for about 0.4 VMAF, with no sharp knee in the numbers, so judge by eye. CRF 42 comes out around VMAF 97.
- **Banding vs detail:** with grain on, banding measures 0 at every CRF tested. Detail loss is what limits the CRF.
- **Preset 3 vs preset 2:** 1.5–1.7× faster in clip tests (about 2× on full runs), about 7% larger at the same CRF, −0.3 VMAF, and hard to see.
- **Full-length speed:** preset 2 runs at 2.4–2.7 fps on full-length 1080p 10-bit films (about 27 h per 2h20m). Short files can be slower: 2.0 fps on a 4-minute file. That's 25–40% slower than a 5-second clip predicts, so budget about 0.7× the clip speed.

## Pitfalls

- **Metric frame pairing:** ffmpeg's `libvmaf`/`psnr` filters can pair the reference and the encode one frame apart, for example because MKV rounds timestamps to 1 ms. Apply `settb=<1/fps>,setpts=N` to both inputs (`av1-eval.sh` does this), or run the `vmaf` command-line tool on two y4m files (the reference must be the exact encoder input). When piping an MKV into y4m, use `-fps_mode passthrough`.
- **Grain in metrics:** libdav1d applies film grain by default. Use `-filmgrain 0` for VMAF. With grain applied, CAMBI reads about 0 no matter what.
- **Seeking:** seeking into the middle of an h264 or m2ts stream corrupts the first decoded frames, so start decoding a few seconds earlier.
- **Hidden output:** `-v error` hides `metadata=print` output, such as `signalstats` values.
- **ffprobe field order:** `-show_entries` returns fields in ffprobe's own order, not the order you asked for, so parse them by key (`-of default=nw=1`).
- **zsh traps:**
  - A glob that matches nothing aborts the whole command.
  - `$var:x` is read as a modifier (`$cells:layout`), so write `${var}`.
  - Quote `'1:a?'`, because `?` is a wildcard.
  - `"${arr:t}"` inside quotes joins the array first, so use `${arr[@]:t}`.
  - `$EPOCHREALTIME` needs `zmodload zsh/datetime`.
  - Don't name a function `cmp`, because it clashes with the system command.
- **Timing and disk:** time only on an idle machine. Clip timings vary by about ±30%. SVT warns that film grain is slow above preset 6. The `.ivf` and `.mp4` exist together for a while, so leave disk space for both.
