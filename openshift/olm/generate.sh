#!/bin/bash

set -e

VERSION="v0.12.1"
OUTFILE="knative-serving.catalogsource.yaml"

sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-queue|$\{IMAGE_QUEUE\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-activator|$\{IMAGE_activator\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-autoscaler|$\{IMAGE_autoscaler\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-autoscaler-hpa|$\{IMAGE_autoscaler_hpa\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-controller|$\{IMAGE_controller\}|g" $OUTFILE
sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-$VERSION:knative-serving-webhook|$\{IMAGE_webhook\}|g" $OUTFILE
