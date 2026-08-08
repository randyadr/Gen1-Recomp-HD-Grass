ONE-CLICK UPDATE / PUBLISH
==========================

Why overwriting files did not push anything:
A downloaded ZIP is just files. It does not contain Git's hidden .git folder,
so Windows has no connection between that folder and your GitHub repository.

FIRST TIME / EVERY UPDATE
1. Make sure this public GitHub repo exists:
   https://github.com/randyadr/gen1recomp-grass-obj-replacer
2. Extract this repo ZIP to a normal folder.
3. Overwrite/change whatever mod files you want.
4. Double-click PUBLISH_UPDATE.bat.
5. Sign into GitHub if Git for Windows asks you to authenticate.

PUBLISH_UPDATE.bat will:
- connect a ZIP-extracted folder to your GitHub repository if needed
- detect your changed files
- automatically bump the patch version (for example 3.4.0 -> 3.4.1)
- git add everything
- create the commit
- push main to GitHub

The included GitHub Action now runs on EVERY push to main. It automatically:
- reads manifest.json
- builds the installable Gen1Recomp ZIP
- creates v<version> if it does not exist
- uploads/replaces the correctly named release asset

That GitHub Release is what Gen1Recomp's automatic update check sees.

REQUIREMENT
You need Git for Windows installed for PUBLISH_UPDATE.bat.
