#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1
output_file="openshift/release/knative-serving-${release}.yaml"

if [ "$release" = "ci" ]; then
    image_prefix="image-registry.openshift-image-registry.svc:5000/knative-serving/knative-serving-"
    tag=""
else
    image_prefix="quay.io/openshift-knative/knative-serving-"
    tag=$release
fi

resolve_resources config/ "$output_file" "$image_prefix" "$tag"