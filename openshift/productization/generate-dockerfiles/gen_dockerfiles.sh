#!/bin/bash -x

target_dir=$1

component=Serving

for subcomponent in Activator Autoscaler Autoscaler-HPA Controller \
                    Networking-Istio Networking-CertManager Networking-NSCert \
                    Queue Webhook; \
do
    export CAPITALIZED_COMPONENT=$component
    export CAPITALIZED_SUBCOMPONENT=$(echo -e "$subcomponent" | sed -e 's/-/ /g')
    export COMPONENT=$(echo -e "$component" | sed -e 's/\(.*\)/\L\1/g')
    export SUBCOMPONENT=$(echo -e "$subcomponent" | sed -e 's/\(.*\)/\L\1/g')
    export VERSION=$(git rev-parse --abbrev-ref HEAD | sed -r 's/release-//g')
    export GO_PACKAGE=$(echo -e "$SUBCOMPONENT" | sed -e 's/networking-/networking\//g')
    envsubst \
      < openshift/productization/generate-dockerfiles/Dockerfile.in \
      > ${target_dir}/Dockerfile.$SUBCOMPONENT
done
