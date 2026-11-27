# MST2 AA / CarPlay Volume Patch

**Free for all by lols11.**

Adds separate music gain sliders for Android Auto and Apple CarPlay to the MIB STD2 Toolbox Green Menu. Each slider ranges from `-13` to `13`, with `-4` as the factory value and `0` as nominal. Changes save to the boot audio table and load when the unit restarts.

Download [`aa_carplay_vol_patch.zip` from v1.1](https://github.com/lols11/mst2_aa_carplay_vol_patch/releases/tag/v1.1).

## Compatibility

| Firmware | Supported layouts |
| --- | --- |
| EU P0478T | Original i.MX6 audio startup |
| EU P0480T | Stock J5 and Toolbox CP |
| `MST2_US_VW_PQ_P0478T` (17220) | Stock J5 and Toolbox CP |

The installation ZIP ships patch code, small byte differences and fingerprints. The installer reads `audiomgr`, `compiled.dat` and the J5 configuration from the unit. It checks the original bytes at every patch location and verifies full-file fingerprints before switching to the patched backend. It uses SHA-256 when `sha256sum` is available. The QNX fallback reads the CRC32 and byte count from `gzip`.

## Install or update

1. Extract `aa_carplay_vol_patch.zip` to the root of the Toolbox SD card. Merge the `custom` folder with the one already on the card.
2. In **MIBSTD2 Toolbox → Customization → GreenMenu**, select **Copy custom Green Engineering Menu screens and scripts to unit**.
3. Reopen Green Menu and select **MIBSTD2 Toolbox → aa_carplay_vol_patch**. The copy replaces the old `aa_volume.esd` with a comment-only compatibility file, leaving one patch screen.
4. Select **Install AA backend**, then **Reboot unit**. Open the patch screen to adjust the sliders. **Backend status** shows both saved gain values.

## Restore factory audio

Select **Restore original backend**, then **Reboot unit**. This restores the original audio startup command and audio table. Both gains return to `-4`.

## Source and build

To rebuild the release ZIP, use Python 3 and the `arm-linux-gnueabi-*` toolchain. Place the matching audiomgr images and stock audio table at the paths in [`aa_volume_build.py`](aa_volume_build.py).

```sh
python3 -B aa_volume_build.py
```
