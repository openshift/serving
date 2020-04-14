#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/../test/e2e-common.sh"
source "$(dirname "$0")/release/resolve.sh"

set -x

readonly SERVING_NAMESPACE=knative-serving
readonly SERVING_INGRESS_NAMESPACE=knative-serving-ingress

# A golang template to point the tests to the right image coordinates.
# {{.Name}} is the name of the image, for example 'autoscale'.
readonly TEST_IMAGE_TEMPLATE="${IMAGE_FORMAT//\$\{component\}/knative-serving-test-{{.Name}}}"

# The OLM global namespace was moved to openshift-marketplace since v4.2
# ref: https://jira.coreos.com/browse/OLM-1190
readonly OLM_NAMESPACE="openshift-marketplace"

env

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset
  machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} "${machineset}" -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} "${machineset}" 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for _ in {1..150}; do  # timeout after 15 minutes
    local available
    available=$(oc get machineset -n "$1" "$2" -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "Error: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

# Waits until the given hostname resolves via DNS
# Parameters: $1 - hostname
function wait_until_hostname_resolves() {
  echo -n "Waiting until hostname $1 resolves via DNS"
  for _ in {1..150}; do  # timeout after 15 minutes
    local output
    output=$(host -t a "$1" | grep 'has address')
    if [[ -n "${output}" ]]; then
      echo -e "\n${output}"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo -e "\n\nERROR: timeout waiting for hostname $1 to resolve via DNS"
  return 1
}

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function install_knative(){
  header "Installing Knative"

  oc new-project $SERVING_NAMESPACE

  # Install CatalogSource in OLM namespace
  export IMAGE_QUEUE=${IMAGE_FORMAT//\$\{component\}/knative-serving-queue}
  export IMAGE_activator=${IMAGE_FORMAT//\$\{component\}/knative-serving-activator}
  export IMAGE_autoscaler=${IMAGE_FORMAT//\$\{component\}/knative-serving-autoscaler}
  export IMAGE_autoscaler_hpa=${IMAGE_FORMAT//\$\{component\}/knative-serving-autoscaler-hpa}
  export IMAGE_controller=${IMAGE_FORMAT//\$\{component\}/knative-serving-controller}
  export IMAGE_webhook=${IMAGE_FORMAT//\$\{component\}/knative-serving-webhook}
  # Kourier is not built in this project.
  # export IMAGE_kourier=${IMAGE_FORMAT//\$\{component\}/kourier}
  export IMAGE_kourier="quay.io/3scale/kourier:v0.3.11"
  envsubst < openshift/olm/knative-serving.catalogsource.yaml | oc apply -n $OLM_NAMESPACE -f -
  timeout 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c serverless) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  # Deploy Serverless Operator
  deploy_serverless_operator

  # Wait for the CRD to appear
  timeout 900 '[[ $(oc get crd | grep -c knativeservings) -eq 0 ]]' || return 1

  # Install Knative Serving
  cat <<-EOF | oc apply -f -
apiVersion: operator.knative.dev/v1alpha1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: ${SERVING_NAMESPACE}
EOF

  # Wait for 4 pods to appear first
  timeout 900 '[[ $(oc get pods -n $SERVING_NAMESPACE --no-headers | wc -l) -lt 4 ]]' || return 1
  wait_until_pods_running $SERVING_NAMESPACE || return 1

  wait_until_service_has_external_ip $SERVING_INGRESS_NAMESPACE kourier || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves "$(kubectl get svc -n $SERVING_INGRESS_NAMESPACE kourier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  header "Knative Installed successfully"
}

function deploy_serverless_operator(){
  local name="serverless-operator"
  local operator_ns
  operator_ns=$(kubectl get og --all-namespaces | grep global-operators | awk '{print $1}')

  # Create configmap to use the latest manifest.
  oc create configmap ko-data -n $operator_ns --from-file="openshift/release/knative-serving-ci.yaml"

  cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}-subscription
  namespace: ${operator_ns}
spec:
  source: ${name}
  sourceNamespace: $OLM_NAMESPACE
  name: ${name}
  channel: techpreview
EOF
}

function run_e2e_tests(){
  echo ">> Creating test resources for OpenShift (test/config/)"
  oc apply -f test/config

  oc adm policy add-scc-to-user privileged -z default -n serving-tests
  oc adm policy add-scc-to-user privileged -z default -n serving-tests-alt
  # adding scc for anyuid to test TestShouldRunAsUserContainerDefault.
  oc adm policy add-scc-to-user anyuid -z default -n serving-tests

  header "Running tests"
  failed=0

  export GATEWAY_OVERRIDE=kourier
  export GATEWAY_NAMESPACE_OVERRIDE="$SERVING_INGRESS_NAMESPACE"
  export INGRESS_CLASS=kourier.ingress.networking.knative.dev

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -short -parallel=3 \
    ./test/e2e \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=3 \
    ./test/conformance/runtime/... \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain "$(ingress_class)" || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=3 \
    ./test/conformance/api/... \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain "$(ingress_class)" || failed=1

  # Prevent HPA from scaling to make the tests more stable
  oc -n "$SERVING_NAMESPACE" patch hpa activator --patch '{"spec":{"maxReplicas":2}}' || return 1

  # Use sed as the -spoofinterval parameter is not available yet
  sed "s/\(.*requestInterval =\).*/\1 10 * time.Millisecond/" -i vendor/knative.dev/pkg/test/spoof/spoof.go

  report_go_test \
    -v -tags=e2e -count=1 -timeout=10m -parallel=1 \
    ./test/ha \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain "$(ingress_class)"|| failed=1

  return $failed
}

scale_up_workers || exit 1

failed=0
(( !failed )) && install_knative || failed=1
(( !failed )) && run_e2e_tests || failed=1
(( failed )) && dump_cluster_state
(( failed )) && exit 1

success
