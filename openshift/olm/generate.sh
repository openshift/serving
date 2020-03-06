#!/usr/bin/env bash

# NOTE: This knative-serving.catalogsource.yaml is generaed by catalog.sh in serverless-operator.
#       Then, change image name to adjust for CI script.
#
# git clone https://github.com/openshift-knative/serverless-operator.git
# cd serverless-operator && bash hack/catalog.sh > $OUTFILE

set -e

VERSION="v0.12.1"
OUTFILE="knative-serving.catalogsource.yaml"

sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-queue|$\{IMAGE_QUEUE\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-activator|$\{IMAGE_activator\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-autoscaler|$\{IMAGE_autoscaler\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-autoscaler-hpa|$\{IMAGE_autoscaler_hpa\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-controller|$\{IMAGE_controller\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-webhook|$\{IMAGE_webhook\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:kourier|$\{IMAGE_kourier\}|g" $OUTFILE
