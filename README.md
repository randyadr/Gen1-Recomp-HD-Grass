# Grass OBJ Replacer V3 — Dramatic + Dramaless

A Gen1Recomp companion mod that replaces the upright voxel-style tall-grass clumps from **Dramaless Shape** or **Dramatic Shape** with a custom 3D OBJ model while leaving the voxel ground underneath intact.

Maintained by **randyadr**.

## Features

- Replaces the voxel renderer's upright grass at the live `ChunkMesher.grass()` / `Voxel3D.draw()` seam instead of competing with the voxel world pipeline.
- Works with **Dramaless Shape** and **Dramatic Shape** compatibility paths.
- Uses the bundled `assets/sht_grass.obj` and texture atlas.
- Indexed OBJ geometry: 146 reusable vertices for the 106-triangle source model instead of expanding every triangle vertex per tuft.
- 64×64 world-pixel spatial chunks, lazy GPU mesh construction, conservative screen culling, and idle mesh eviction.
- Keeps wind/player interaction on modern voxel builds.
- Legacy/Dramaless CPU-wind fallback updates at a fixed **60 Hz**.
- **V3.4 faster wind:** sway speed is `6.0 rad/s`, roughly one full sine cycle per second instead of the much slower previous default.

## Requirements

Install and enable **either** Dramaless Shape (`DRAMALESS_SHAPE`) **or** Dramatic Shape (`DRAMATIC_SHAPE`) and use its voxel display mode.

The mod uses the Gen1Recomp `engine_internals` permission because Dramaless compatibility must locate and patch the live voxel renderer tables.

## Install

1. Download the release ZIP whose filename begins with `DRAMATIC_SHAPE_GRASS_OBJ_REPLACER_V3-`.
2. In Gen1Recomp, use **MODS → Import mod .zip** (or extract it into the mods directory).
3. Enable the grass replacer and your voxel mod.
4. Turn on the voxel display mode and restart once after first installation/upgrade if needed.

The manifest contains:

```json
"github": "randyadr/gen1recomp-grass-obj-replacer"
```

That lets Gen1Recomp's **Update** / **Versions** flow follow installable ZIP assets from this repository's GitHub Releases.

## Releasing a new version

1. Change `version` in `manifest.json` and update `CHANGELOG.md`.
2. Commit and push to `main`.
3. Either tag the commit as `vX.Y.Z`, or open **Actions → Build Gen1Recomp Release → Run workflow**.
4. The workflow builds an installable root-layout ZIP named:

   `DRAMATIC_SHAPE_GRASS_OBJ_REPLACER_V3-X.Y.Z.zip`

   and publishes/uploads it to the matching GitHub Release.

Once the mod is accepted into the Gen1Recomp mod index with automatic version checking enabled, future releases are picked up by the index without a new index PR for each version.

## Build a release locally

```bash
python3 tools/build_release.py
```

The installable archive is written to `dist/`.

## License / assets

The Lua code and repository tooling are MIT licensed. The bundled model/textures are **not** covered by the MIT code license; see `ASSET-NOTICE.md`.
