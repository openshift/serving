#!/usr/bin/env bash

OUTFILE="knative-serving.catalogsource.yaml"

TMPDIR=$(mktemp -d)
git clone --depth 1 https://github.com/openshift-knative/serverless-operator.git ${TMPDIR}
VERSION=$(ls ${TMPDIR}/olm-catalog/serverless-operator/ |sort -n |tail -1)
OLM_DIR=${TMPDIR}/olm-catalog/serverless-operator/${VERSION}

indent() {
  INDENT="      "
  ENDASH="    - "
  sed "s/^/$INDENT/" | sed "s/^${INDENT}\($1\)/${ENDASH}\1/"
}

export IMAGE_KNATIVE_OPERATOR="registry.ci.openshift.org/openshift/openshift-serverless-nightly:knative-operator"
export IMAGE_KNATIVE_OPENSHIFT_INGRESS="registry.ci.openshift.org/openshift/openshift-serverless-nightly:knative-openshift-ingress"

CRD=$(cat $(ls $OLM_DIR/*_crd.yaml) | grep -v -- "---" | indent apiVersion)
CSV=$(cat $(find $OLM_DIR -name '*version.yaml' | grep "${VERSION}" | sort -n) | envsubst '$IMAGE_KNATIVE_OPERATOR $IMAGE_KNATIVE_OPENSHIFT_INGRESS' | indent apiVersion)
PKG=$(cat minimum.package.yaml | indent packageName)

cat <<EOF | sed '/replaces:/d' | sed 's/^  *$//' > ${OUTFILE}
kind: ConfigMap
apiVersion: v1
metadata:
  name: serverless-operator

data:
  customResourceDefinitions: |-
$CRD
  clusterServiceVersions: |-
$CSV
  packages: |-
$PKG
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: serverless-operator
spec:
  configMap: serverless-operator
  displayName: "Serverless Operator"
  publisher: Red Hat
  sourceType: internal
EOF
