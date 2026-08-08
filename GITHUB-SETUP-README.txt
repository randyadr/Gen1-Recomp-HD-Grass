GRASS OBJ REPLACER - GITHUB AUTO UPDATE SETUP
================================================

The previous package had one missing step: it assumed this repository already existed:

  randyadr/gen1recomp-grass-obj-replacer

Gen1Recomp calls GitHub's public Releases API for that exact repo. If the repo is missing
or private, GitHub returns HTTP 404 before Gen1Recomp ever looks at the mod ZIP.

FIRST USE
---------
1. Extract this whole repository ZIP to a normal folder.
2. Double-click FIRST_TIME_SETUP.bat.
3. If GitHub CLI needs login, complete the browser login as randyadr.
4. The script will:
   - install Git/GitHub CLI with winget if needed
   - create randyadr/gen1recomp-grass-obj-replacer as a PUBLIC repo if missing
   - push this source repo
   - create the current v3.4.0 GitHub Release immediately
   - upload DRAMATIC_SHAPE_GRASS_OBJ_REPLACER_V3-3.4.0.zip
   - call the exact public API URL used by Gen1Recomp and verify it works
5. Restart Gen1Recomp and open F10.

FUTURE UPDATES
--------------
1. Replace/edit files in this SAME extracted repo folder.
2. Double-click PUBLISH_UPDATE.bat.
3. It automatically bumps 3.4.0 -> 3.4.1, commits, pushes, waits for GitHub Actions,
   verifies the Release was created, and only then reports success.

CHECK ONLY
----------
Double-click CHECK_GITHUB_UPDATE.bat. HTTP 200 means the repo endpoint itself is live.
