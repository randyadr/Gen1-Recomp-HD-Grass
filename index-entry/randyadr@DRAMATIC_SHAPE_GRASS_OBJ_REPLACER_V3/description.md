# Grass OBJ Replacer V3 - Dramatic + Dramaless

Replaces the upright voxel-style tall-grass clumps rendered by **Dramaless Shape** or **Dramatic Shape** with a custom 3D OBJ model. The voxel terrain / grass-colored ground below the clumps is left intact.

## What it changes

- Hooks the live voxel grass rendering seam instead of registering a competing world renderer.
- Uses indexed custom OBJ geometry and 64×64 world-pixel spatial chunks.
- Lazily builds visible chunks, culls off-screen chunks, and evicts idle GPU meshes.
- Keeps the modern voxel renderer's grass/player interaction where available.
- Provides a fixed 60 Hz legacy/Dramaless CPU wind fallback.
- V3.4 increases wind speed to roughly one complete sway cycle per second.

## Install

1. Download the installable release ZIP from the mod's GitHub Releases.
2. In Gen1Recomp, use **MODS → Import mod .zip**.
3. Enable this mod and either Dramaless Shape or Dramatic Shape.
4. Enable the voxel display mode.

With the repository configured in the manifest, Gen1Recomp's **Update** and **Versions** controls can follow future GitHub Releases.

## Compatibility

- Mod API 2.
- Requires either `DRAMALESS_SHAPE` or `DRAMATIC_SHAPE` to be enabled at runtime.
- Uses `engine_internals` for the Dramaless live-renderer compatibility bridge.
- Does not affect link gameplay state.

## License

Lua source/tooling: MIT. Bundled custom model/textures are not covered by the MIT code license; see the repository's asset notice.
