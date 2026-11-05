# Copy the addon into a game flavor's AddOns folder; /reload in game afterwards
sync flavor="forever":
    ./deploy.sh {{flavor}}

# Package the addon for a CurseForge upload
build:
    ./build.sh
