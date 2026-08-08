# Changelog

## 3.4.0
- Increased grass sway speed from the previous ~2.15–2.35 rad/s range to **6.0 rad/s**.
- Modern GPU-wind voxel builds now receive the same faster wind rate through `Voxel3D.GRASS_WIND_SPEED`.
- Legacy / Dramaless CPU-wind remains fixed at **60 Hz**; only the motion speed changed.
- Added GitHub update metadata for `randyadr/gen1recomp-grass-obj-replacer`.
- Added a GitHub Actions release workflow that creates index-compatible installable ZIP assets.
- Added a ready-to-copy Gen1Recomp mod-index entry.

## 3.3.0
- Dramaless / legacy CPU grass wind advances at a fixed **60 Hz** real-time cadence instead of 12 Hz.
- Animation cadence is independent of game-speed multipliers.
- Precomputed vertex phase sine/cosine and bend weights to reduce per-frame CPU math.

## 3.2.0
- Added dual compatibility with Dramaless Shape and Dramatic Shape.

## 3.1.0
- Converted the OBJ to indexed runtime geometry.
- Replaced one whole-map grass mesh with lazy 64×64-world-pixel chunks.
- Added conservative camera culling and idle GPU chunk eviction.

## 3.0.0
- First hard replacement that substituted the voxel renderer's upright grass with the custom OBJ.
