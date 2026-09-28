# script-encoding

Notes and scripts for encoding video to AV1 (SVT-AV1) and audio to AAC on macOS.

| File | Contents |
|---|---|
| [av1.md](av1.md) | AV1 video: recipe, source checks, choosing CRF and preset, test findings, running long jobs, pitfalls |
| [bdrip.md](bdrip.md) | Blu-ray → AV1 + AAC MP4: disc inspection, audio, metadata and chapters, merge, verify, naming |
| `scripts/av1-encode.sh` | Encodes a list of files one after another with the AV1 recipe, logging an ETA and verifying each output |
| `scripts/av1-testclip.sh` | Extracts a lossless test clip |
| `scripts/av1-eval.sh` | Encodes a test clip and reports bitrate, speed, VMAF and CAMBI (banding) |
| `scripts/av1-crops.sh` | Builds an image grid of the source next to encodes, with optional brightness boost |
| `scripts/apple-aac.sh` | AAC 256k encode the way Apple Digital Masters does (`afconvert`) |
| `scripts/ffmpeg-fix-aac-vbr-header.py` | Restores the AAC VBR header fields that ffmpeg overwrites when muxing |

Requirements: zsh, ffmpeg and ffprobe (with libdav1d and libvmaf), `SvtAv1EncApp` (SVT-AV1 4.2 or later), `afconvert` (built into macOS), python3, mediainfo.

```sh
scripts/av1-encode.sh -c 46 -p 2 movie.mp4
```
