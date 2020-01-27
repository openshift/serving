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

# Update openshift's master and take all needed files from there.
git fetch openshift master
git checkout openshift/master -- openshift OWNERS_ALIASES OWNERS Makefile content_sets.yml container.yaml
make generate-dockerfiles
make generate-p12n-dockerfiles
make RELEASE=$release generate-release
make RELEASE=ci generate-release
git add openshift OWNERS_ALIASES OWNERS Makefile content_sets.yml container.yaml
git commit -m "Add openshift specific files."
