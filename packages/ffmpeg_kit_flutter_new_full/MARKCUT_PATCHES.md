# MarkCut native artifact integrity patch

Based on pub.dev `ffmpeg_kit_flutter_new_full` 2.5.2, retaining its license and Dart/native API.

- `scripts/setup_ios.sh`: pin the 8.1.2-full iOS ZIP SHA-256, verify before extraction, and verify installed framework files before reusing the cache. Mirrors must serve identical bytes.
- `ios/ffmpeg_kit_flutter_new_full.podspec`: always invoke the verifier; the app's Podfile also invokes it because local pods can skip prepare commands.
- Expected ZIP: `ffmpeg-kit-ios-full-8.1.2.zip`, 49,189,844 bytes.
- SHA-256: `ced6cdeba06ce0722600de2cba3620cc1af5cc83d0f04cb5d116416ec32bcd20`.
- Provenance: [upstream release metadata](https://api.github.com/repos/sk3llo/ffmpeg_kit_flutter/releases/tags/8.1.2-full), checked 2026-09-27; re-checked 2026-10-06. Updating requires reviewing and pinning the new artifact, not taking an environment-supplied digest.
- 2026-10-06 re-pin: upstream replaced the asset on 2026-10-05 14:38 UTC (all eight 8.1.2 Apple variants within 11 minutes) right after commit [8befff9](https://github.com/sk3llo/ffmpeg_kit_flutter/commit/8befff96bb), which drops the AppleDouble `._*` files that `ditto -c -k` had stored next to every file (issue #170, macOS CodeSign failure) and states the repacked contents are byte-identical. The size change (49,275,024 → 49,189,844 bytes) fits that. The previous pin was `bdefd779553cb5636e36aeec9ba8cb4d04ee88381fc26c2d5447c2950a29ac0b`; with it every iOS build stopped at CocoaPods with "SHA-256 mismatch".

This patch verifies artifact identity. It does not assert that every bundled codec is vulnerability-free. Android's separate media_kit/libmpv binary needs its own patch inventory.
