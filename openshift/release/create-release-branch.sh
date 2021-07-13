#!/bin/bash -e

# Usage: create-release-branch.sh v0.4.1 release-v0.4.1

release=$1
target=$2
release_regexp="^release-v([0-9]+\.)+([0-9])$"

if [[ ! $target =~ $release_regexp ]]; then
    echo "\"$target\" is wrong format. Must have proper format like release-v0.1.2"
    exit 1
fi

# Fetch the latest tags and checkout a new branch from the wanted tag.
git fetch upstream --tags
git checkout -b "$target" "$release"

# Update openshift's main and take all needed files from there.
git fetch openshift main
git checkout openshift/main -- openshift OWNERS_ALIASES OWNERS Makefile
make generate-dockerfiles
make RELEASE=$release generate-release
make RELEASE=ci generate-release
git add openshift OWNERS_ALIASES OWNERS Makefile
git commit -m "Add openshift specific files."
