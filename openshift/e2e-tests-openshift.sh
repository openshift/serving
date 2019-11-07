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
readonly SERVICEMESH_NAMESPACE=knative-serving-ingress
export GATEWAY_OVERRIDE="kourier"
export GATEWAY_NAMESPACE_OVERRIDE="$SERVING_NAMESPACE"
readonly TARGET_IMAGE_PREFIX="$INTERNAL_REGISTRY/$SERVING_NAMESPACE/knative-serving-"

# The OLM global namespace was moved to openshift-marketplace since v4.2
# ref: https://jira.coreos.com/browse/OLM-1190
if [ ${HOSTNAME} = "e2e-aws-ocp-41" ]; then
  readonly OLM_NAMESPACE="openshift-operator-lifecycle-manager"
else
  readonly OLM_NAMESPACE="openshift-marketplace"
fi

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

function install_knative(){
  # OLM doesn't support dependency resolution on 4.1 yet. Install the operator manually.
  if [ ${HOSTNAME} = "e2e-aws-ocp-41" ]; then
    # Install the ServiceMesh Operator
    oc apply -f openshift/servicemesh/operator-install.yaml

    # Wait for the istio-operator pod to appear
    timeout 900 '[[ $(oc get pods -n openshift-operators | grep -c istio-operator) -eq 0 ]]' || return 1

    # Wait until the Operator pod is up and running
    wait_until_pods_running openshift-operators || return 1
  fi

  header "Installing Knative"

  oc new-project $SERVING_NAMESPACE

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
spec:
  config:
    network:
      clusteringress.class: "kourier.ingress.networking.knative.dev"
      ingress.class: "kourier.ingress.networking.knative.dev"
EOF

  # Create imagestream for images generated in CI namespace
  tag_core_images openshift/release/knative-serving-ci.yaml

  # Wait for 4 pods to appear first
  timeout 900 '[[ $(oc get pods -n $SERVING_NAMESPACE --no-headers | wc -l) -lt 4 ]]' || return 1
  wait_until_pods_running $SERVING_NAMESPACE || return 1

  # wait_until_service_has_external_ip $SERVICEMESH_NAMESPACE istio-ingressgateway || fail_test "Ingress has no external IP"
  # wait_until_hostname_resolves "$(kubectl get svc -n $SERVICEMESH_NAMESPACE istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  header "Knative Installed successfully"
}

function deploy_serverless_operator(){
  local NAME="serverless-operator"

  cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NAME}-subscription
  namespace: openshift-operators
spec:
  source: ${NAME}
  sourceNamespace: $OLM_NAMESPACE
  name: ${NAME}
  channel: techpreview
EOF
}

function install_kourier(){
  header "Install Kourier"
    
  # TODO: GIANT HACKS BELOW
  # we still need the Istio CRDs, for now...
  oc apply -f https://raw.githubusercontent.com/knative/serving/release-0.9/third_party/istio-1.1.13/istio-crds.yaml

  # And stub out some namespaces
  oc create ns knative-serving
  oc create ns knative-serving-ingress

  # Our operator specifically checks for the ServiceMeshMemberRoll...
  cat <<EOF | oc apply -f -
apiVersion: apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  name: servicemeshcontrolplanes.maistra.io
spec:
  group: maistra.io
  names:
    kind: ServiceMeshControlPlane
    listKind: ServiceMeshControlPlaneList
    plural: servicemeshcontrolplanes
    singular: servicemeshcontrolplane
    shortNames:
      - smcp
  scope: Namespaced
  version: v1
  additionalPrinterColumns:
  - JSONPath: .status.conditions[?(@.type=="Ready")].status
    name: Ready
    description: Whether or not the control plane installation is up to date and ready to handle requests.
    type: string
  - JSONPath: .status.conditions[?(@.type=="Ready")].message
    name: Status
    description: The status of the control plane installation.
    type: string
    priority: 1
  - JSONPath: .status.conditions[?(@.type=="Reconciled")].status
    name: Reconciled
    description: Whether or not the control plane installation is up to date with the latest version of this resource.
    type: string
    priority: 1
  - JSONPath: .status.conditions[?(@.type=="Reconciled")].message
    name: Reconciliation Status
    description: The status of the reconciliation process, if the control plane is not up to date with the latest version this resource.
    type: string
    priority: 1
---
apiVersion: apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  name: servicemeshmemberrolls.maistra.io
spec:
  group: maistra.io
  names:
    kind: ServiceMeshMemberRoll
    listKind: ServiceMeshMemberRollList
    plural: servicemeshmemberrolls
    singular: servicemeshmemberroll
    shortNames:
      - smmr
  scope: Namespaced
  version: v1
  additionalPrinterColumns:
  - JSONPath: .spec.members
    description: Namespaces that are members of this Control Plane
    name: Members
    type: string
EOF

  # sleep a bit (for CRDs to get registered)
  sleep 15

  # Now create a fake SMMR
  cat <<EOF | oc apply -f -
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: knative-serving-ingress
spec:
  members:
  - serving-tests
  - serving-tests-alt
  - ${SERVING_NAMESPACE}
status:
  configuredMembers:
  - serving-tests
  - serving-tests-alt
  - ${SERVING_NAMESPACE}
EOF

  # And a fake SMCP
  cat <<EOF | oc apply -f -
apiVersion: maistra.io/v1
kind: ServiceMeshControlPlane
metadata:
  name: basic-install
  namespace: knative-serving-ingress
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
        labels:
          maistra-control-plane: knative-serving-ingress
      istio-egressgateway:
        enabled: false
      cluster-local-gateway:
        autoscaleEnabled: false
        enabled: true
        labels:
          app: cluster-local-gateway
          istio: cluster-local-gateway
          maistra-control-plane: knative-serving-ingress
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
status:
  conditions:
  - message: Successfully installed all mesh components
    reason: InstallSuccessful
    status: "True"
    type: Installed
  - message: Successfully updated from version 1.0.0-1 to version 1.0.1-8.el8-1
    reason: UpdateSuccessful
    status: "True"
    type: Reconciled
  - message: All component deployments are Available
    reason: ComponentsReady
    status: "True"
    type: Ready
EOF

  # Install Kourier
  curl -L https://raw.githubusercontent.com/3scale/kourier/v0.2.2/deploy/kourier-knative.yaml \
      | sed 's/ClusterIP/LoadBalancer/' \
      | oc apply -f -

  # Wait for the kourier pod to appear
  timeout 900 '[[ $(oc get pods -n $SERVING_NAMESPACE | grep -c 3scale-kourier) -eq 0 ]]' || return 1

  # Wait until all kourier pods are up
  wait_until_pods_running $SERVING_NAMESPACE

  wait_until_service_has_external_ip $SERVING_NAMESPACE kourier || fail_test "Kourier Ingress has no external IP"
  wait_until_hostname_resolves "$(kubectl get svc -n $SERVING_NAMESPACE kourier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  header "Kourier installed successfully"
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
  oc logs deployment/knative-openshift-ingress -n $SERVING_NAMESPACE
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

(( !failed )) && install_kourier || failed=1

(( !failed )) && install_knative || failed=1

(( !failed )) && create_test_resources_openshift || failed=1

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

(( failed )) && dump_openshift_olm_state

(( failed )) && dump_openshift_ingress_state

(( failed )) && exit 1

success
