#!/usr/bin/env bash

source $(dirname $0)/../test/e2e-common.sh
source $(dirname $0)/release/resolve.sh

set -x

readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-"image-registry.openshift-image-registry.svc:5000"}"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly TEST_NAMESPACE=serving-tests
readonly TEST_NAMESPACE_ALT=serving-tests-alt
readonly SERVING_NAMESPACE=knative-serving
readonly TARGET_IMAGE_PREFIX="$INTERNAL_REGISTRY/$SERVING_NAMESPACE/knative-serving-"
readonly OLM_NAMESPACE="openshift-operator-lifecycle-manager"

env

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} ${machineset} -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} ${machineset} 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for i in {1..150}; do  # timeout after 15 minutes
    local available=$(oc get machineset -n $1 $2 -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "\n\nError: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

# Waits until the given hostname resolves via DNS
# Parameters: $1 - hostname
function wait_until_hostname_resolves() {
  echo -n "Waiting until hostname $1 resolves via DNS"
  for i in {1..150}; do  # timeout after 15 minutes
    local output="$(host -t a $1 | grep 'has address')"
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

function install_istio(){
  header "Installing ServiceMesh"

  # Install the ServiceMesh Operator
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: CatalogSourceConfig
metadata:
  name: ci-operators
  namespace: openshift-marketplace
spec:
  targetNamespace: openshift-operators
  packages: elasticsearch-operator,jaeger-product,kiali-ossm,servicemeshoperator
  source: redhat-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: elasticsearch-operator
  namespace: openshift-operators
spec:
  channel: preview
  name: elasticsearch-operator
  source: ci-operators
  sourceNamespace: openshift-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: jaeger-product
  namespace: openshift-operators
spec:
  channel: stable
  name: jaeger-product
  source: ci-operators
  sourceNamespace: openshift-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kiali-ossm
  namespace: openshift-operators
spec:
  channel: stable
  name: kiali-ossm
  source: ci-operators
  sourceNamespace: openshift-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: "1.0"
  name: servicemeshoperator
  source: ci-operators
  sourceNamespace: openshift-operators
EOF

  # Wait for the istio-operator pod to appear
  timeout 900 '[[ $(oc get pods -n openshift-operators | grep -c istio-operator) -eq 0 ]]' || return 1

  # Wait until the Operator pod is up and running
  wait_until_pods_running openshift-operators || return 1

  # Deploy ServiceMesh
  oc new-project istio-system
  cat <<EOF | oc apply -f -
apiVersion: maistra.io/v1
kind: ServiceMeshControlPlane
metadata:
  name: minimal-multitenant-cni-install
  namespace: istio-system
spec:
  istio:
    global:
      multitenant: true
      proxy:
        autoInject: disabled
      omitSidecarInjectorConfigMap: true
      disablePolicyChecks: false
      defaultPodDisruptionBudget:
        enabled: false
    istio_cni:
      enabled: true
    gateways:
      istio-ingressgateway:
        autoscaleEnabled: false
        type: LoadBalancer
      istio-egressgateway:
        enabled: false
      cluster-local-gateway:
        autoscaleEnabled: false
        enabled: true
        labels:
          app: cluster-local-gateway
          istio: cluster-local-gateway
        ports:
          - name: status-port
            port: 15020
          - name: http2
            port: 80
            targetPort: 8080
          - name: https
            port: 443
    mixer:
      enabled: false
      policy:
        enabled: false
      telemetry:
        enabled: false
    pilot:
      autoscaleEnabled: false
      sidecar: false
    kiali:
      enabled: false
    tracing:
      enabled: false
    prometheus:
      enabled: false
    grafana:
      enabled: false
    sidecarInjectorWebhook:
      enabled: false
---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - serving-tests
  - serving-tests-alt
  - ${SERVING_NAMESPACE}
EOF

  # Wait for the ingressgateway pod to appear.
  timeout 900 '[[ $(oc get pods -n istio-system | grep -c istio-ingressgateway) -eq 0 ]]' || return 1

  wait_until_service_has_external_ip istio-system istio-ingressgateway || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves $(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")

  wait_until_pods_running istio-system

  header "ServiceMesh installed successfully"
}

function install_knative(){
  header "Installing Knative"

  create_knative_namespace serving

  # Install CatalogSource in OLM namespace
  oc apply -n $OLM_NAMESPACE -f openshift/olm/knative-serving.catalogsource.yaml
  timeout 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c serverless) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  # Deploy Serverless Operator
  deploy_serverless_operator

  # Wait for the CRD to appear
  timeout 900 '[[ $(oc get crd | grep -c knativeservings) -eq 0 ]]' || return 1

  # Install Knative Serving
  cat <<-EOF | oc apply -f -
  apiVersion: serving.knative.dev/v1alpha1
  kind: KnativeServing
  metadata:
    name: knative-serving
    namespace: ${SERVING_NAMESPACE}
	EOF

  # Create imagestream for images generated in CI namespace
  tag_core_images openshift/release/knative-serving-ci.yaml

  # Wait for 6 pods to appear first
  timeout 900 '[[ $(oc get pods -n $SERVING_NAMESPACE --no-headers | wc -l) -lt 6 ]]' || return 1
  wait_until_pods_running "$SERVING_NAMESPACE" || return 1

  header "Knative Installed successfully"
}

function create_knative_namespace(){
  local COMPONENT="knative-$1"

  cat <<-EOF | oc apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: ${COMPONENT}
	EOF
}

function deploy_serverless_operator(){
  local NAME="serverless-operator"

  if oc get crd operatorgroups.operators.coreos.com >/dev/null 2>&1; then
    cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: ${NAME}
	  namespace: ${SERVING_NAMESPACE}
	EOF
  fi

  cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: ${NAME}-subscription
	  generateName: ${NAME}-
	  namespace: ${SERVING_NAMESPACE}
	spec:
	  source: ${NAME}
	  sourceNamespace: $OLM_NAMESPACE
	  name: ${NAME}
	  channel: techpreview
	EOF
}

function tag_core_images(){
  local resolved_file_name=$1

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${SERVING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name}
  done
}

function create_test_resources_openshift() {
  echo ">> Creating test resources for OpenShift (test/config/)"

  resolve_resources test/config/ tests-resolved.yaml $TARGET_IMAGE_PREFIX

  tag_core_images tests-resolved.yaml

  oc apply -f tests-resolved.yaml

  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts:${TEST_NAMESPACE} --namespace=${SERVING_NAMESPACE}
  oc policy add-role-to-group system:image-puller system:serviceaccounts:${TEST_NAMESPACE_ALT} --namespace=${SERVING_NAMESPACE}
  oc policy add-role-to-group system:image-puller system:serviceaccounts:knative-testing --namespace=${SERVING_NAMESPACE}

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images
}

function create_test_namespace(){
  oc new-project $TEST_NAMESPACE
  oc new-project $TEST_NAMESPACE_ALT
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE_ALT
  # adding scc for anyuid to test TestShouldRunAsUserContainerDefault.
  oc adm policy add-scc-to-user anyuid -z default -n $TEST_NAMESPACE
}

function run_e2e_tests(){
  header "Running tests"
  failed=0

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -short -parallel=1 \
    ./test/e2e \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --resolvabledomain || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=1 \
    ./test/conformance/runtime/... \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --resolvabledomain || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=1 \
    ./test/conformance/api/v1alpha1/... \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --resolvabledomain || failed=1

  return $failed
}

function delete_knative_openshift() {
  echo ">> Bringing down Knative Serving"
  oc delete --ignore-not-found=true -n $OLM_NAMESPACE -f knative-serving.catalogsource-ci.yaml
  oc delete project $SERVING_NAMESPACE
}

function delete_test_resources_openshift() {
  echo ">> Removing test resources (test/config/)"
  oc delete --ignore-not-found=true -f tests-resolved.yaml
}

function delete_test_namespace(){
  echo ">> Deleting test namespaces"
  oc delete project $TEST_NAMESPACE
  oc delete project $TEST_NAMESPACE_ALT
}

function teardown() {
  delete_test_namespace
  delete_test_resources_openshift
  delete_knative_openshift
}

function dump_openshift_olm_state(){
  echo ">>> subscriptions.operators.coreos.com:"
  oc get subscriptions.operators.coreos.com -o yaml --all-namespaces   # This is for status checking.

  echo ">>> catalog operator log:"
  oc logs -n openshift-operator-lifecycle-manager deployment/catalog-operator
}

function dump_openshift_ingress_state(){
  echo ">>> routes.route.openshift.io:"
  oc get routes.route.openshift.io -o yaml --all-namespaces
  echo ">>> routes.serving.knative.dev:"
  oc get routes.serving.knative.dev -o yaml --all-namespaces

  echo ">>> openshift-ingress log:"
  oc logs deployment/knative-openshift-ingress -n "$SERVING_NAMESPACE"
}

function tag_test_images() {
  local dir=$1
  image_dirs="$(find ${dir} -mindepth 1 -maxdepth 1 -type d)"

  for image_dir in ${image_dirs}; do
    name=$(basename ${image_dir})
    tag_built_image knative-serving-test-${name} ${name}
  done

  # TestContainerErrorMsg also needs an invalidhelloworld imagestream
  # to exist but NOT have a `latest` tag
  oc tag --insecure=${INSECURE} -n ${SERVING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:knative-serving-test-helloworld invalidhelloworld:not_latest
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  oc tag --insecure=${INSECURE} -n ${SERVING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:latest
}

scale_up_workers || exit 1

create_test_namespace || exit 1

failed=0

(( !failed )) && install_istio || failed=1

(( !failed )) && install_knative || failed=1

(( !failed )) && create_test_resources_openshift || failed=1

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

(( failed )) && dump_openshift_olm_state

(( failed )) && dump_openshift_ingress_state

teardown

(( failed )) && exit 1

success
