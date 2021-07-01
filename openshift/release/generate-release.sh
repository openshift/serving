#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1
output_file="openshift/release/knative-serving-${release}.yaml"

resolve_resources "config/core/ config/hpa-autoscaling/ config/domain-mapping/" "$output_file"
