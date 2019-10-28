#!/bin/bash -x

target_dir=$1

component=serving
for subcomponent in controller autoscaler autoscaler-hpa activator networking-istio networking-certmanager networking-nscert webhook queue; do
    CAPITALIZED_COMPONENT=$(echo -e "$component" | sed -r 's/\<./\U&/g') \
    CAPITALIZED_SUBCOMPONENT=$(echo -e "$subcomponent" | sed -r 's/\<./\U&/g') \
    GO_PACKAGE=$(echo -e "$subcomponent" | sed -r 's/-/\//g') \
    COMPONENT=$component \
    SUBCOMPONENT=$subcomponent \
    envsubst < openshift/productization/generate-dockerfiles/Dockerfile.in > ${target_dir}/Dockerfile.$subcomponent
done
