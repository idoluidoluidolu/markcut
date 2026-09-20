# Native scrub fixture

`native-scrub.mp4` is a generated, silent, gray H.264 Baseline video: 64×64,
30 fps, 30 frames, no B frames, keyframes every 10 frames, duration 1 second.
It is included only in the RunnerTests resource phase, not the app target.

The tail, paused-redraw and live-volume tests exercise decoding and composition;
they must not depend on starting a simulator encoder during each test. The old
AVAssetWriter fixture sometimes stayed in `.writing` beyond its 10-second setup
timeout, then handed an incomplete file to the actual test.

Regenerate with FFmpeg:

```sh
ffmpeg -f lavfi -i "color=c=gray:s=64x64:r=30" -frames:v 30 \
  -c:v libx264 -profile:v baseline -pix_fmt yuv420p \
  -g 10 -keyint_min 10 -sc_threshold 0 -bf 0 \
  -video_track_timescale 15360 -movflags +faststart native-scrub.mp4
```

## HDR proxy fixture

`native-hdr-rotated.mp4` contains 90 frames of HEVC Main 10 HLG/BT.2020
at 128x64, 30 fps, 3 seconds, a 90-degree display matrix, and mono AAC audio.
The left half is code value 940 (HDR white), the right half 512; chroma is 512.
It exercises real HDR decoding, highlight preservation, rotation, audio, and
repeated reuse of the proxy's eight-buffer output pool. Tests also assert the
fixture is classified as HDR. It is a RunnerTests-only resource.

```sh
ffmpeg -f lavfi -i "nullsrc=s=128x64:r=30,format=yuv420p10le,geq=lum='if(lt(X,W/2),940,512)':cb=512:cr=512" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 3 \
  -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
  -x265-params "log-level=error:keyint=5:min-keyint=5:scenecut=0:bframes=0:pools=1:colorprim=9:transfer=18:colormatrix=9" \
  -c:a aac -b:a 64k -movflags +faststart hdr-source.mp4
ffmpeg -display_rotation:v:0 90 -i hdr-source.mp4 -c copy \
  -movflags +faststart native-hdr-rotated.mp4
```
