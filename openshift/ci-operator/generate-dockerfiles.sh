#!/bin/bash

set -x

function generate_dockefiles() {
  local target_dir=$1; shift
  for img in $@; do
    local image_base=$(basename $img)
    mkdir -p $target_dir/$image_base
    bin=$image_base envsubst < openshift/ci-operator/Dockerfile.in > $target_dir/$image_base/Dockerfile
    # Add USER 1000 to runtime-unprivileged image
    if [[ $image_base = "runtime-unprivileged" ]]; then
      sed -i '/FROM/a\USER 1000' $target_dir/$image_base/Dockerfile
    fi
  done
}

generate_dockefiles $@
