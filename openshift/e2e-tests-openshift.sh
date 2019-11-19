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
readonly UPGRADE_SERVERLESS="${UPGRADE_SERVERLESS:-"true"}"
readonly UPGRADE_CLUSTER="${UPGRADE_CLUSTER:-"false"}"


if [[ ${HOSTNAME} = e2e-aws-ocp-41* ]]; then
  # The OLM global namespace was moved to openshift-marketplace since v4.2
  # ref: https://jira.coreos.com/browse/OLM-1190
  readonly OLM_NAMESPACE="openshift-operator-lifecycle-manager"
  readonly RUN_UPGRADE_TESTS=true
  readonly INSTALL_PLAN_APPROVAL="Manual"
else
  readonly OLM_NAMESPACE="openshift-marketplace"
  # Skip rolling upgrades on OCP 4.2 because of https://jira.coreos.com/browse/OLM-1299
  readonly RUN_UPGRADE_TESTS=false
  readonly INSTALL_PLAN_APPROVAL="Automatic"
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

function install_servicemesh(){
  header "Installing ServiceMesh"

  install_servicemesh_operator || return 1

  # Deploy ServiceMesh
  oc new-project $SERVICEMESH_NAMESPACE
  oc apply -n $SERVICEMESH_NAMESPACE -f openshift/servicemesh/controlplane-install.yaml
  cat <<EOF | oc apply -f -
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: ${SERVICEMESH_NAMESPACE}
spec:
  members:
  - serving-tests
  - serving-tests-alt
  - ${SERVING_NAMESPACE}
EOF

  # Wait for the ingressgateway pod to appear.
  timeout 900 '[[ $(oc get pods -n $SERVICEMESH_NAMESPACE | grep -c istio-ingressgateway) -eq 0 ]]' || return 1

  wait_until_service_has_external_ip $SERVICEMESH_NAMESPACE istio-ingressgateway || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves "$(kubectl get svc -n $SERVICEMESH_NAMESPACE istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  wait_until_pods_running $SERVICEMESH_NAMESPACE

  header "ServiceMesh installed successfully"
}

function install_servicemesh_operator(){
  # Install the ServiceMesh Operator
  oc apply -f openshift/servicemesh/operator-install.yaml

  # Wait for the istio-operator pod to appear
  timeout 900 '[[ $(oc get pods -n openshift-operators | grep -c istio-operator) -eq 0 ]]' || return 1

  # Wait until the Operator pod is up and running
  wait_until_pods_running openshift-operators || return 1  
}

function install_knative_previous(){
  export SERVICEMESH_NAMESPACE=istio-system
  export GATEWAY_NAMESPACE_OVERRIDE="$SERVICEMESH_NAMESPACE"

  # For the previous release install the whole Service Mesh (including ControlPlane)
  install_servicemesh || return 1

  header "Installing Knative"

  oc new-project $SERVING_NAMESPACE

  # Get the previous CSV
  local csv=$(grep replaces: openshift/olm/knative-serving.catalogsource.yaml | tail -n1 | awk '{ print $2 }')
  # Deploy Serverless Operator
  deploy_serverless_operator $csv

  # Deploy KnativeServing CR
  deploy_knativeserving

  header "Knative Installed successfully"
}

function install_knative_latest(){
  export SERVICEMESH_NAMESPACE=knative-serving-ingress
  export GATEWAY_NAMESPACE_OVERRIDE="$SERVICEMESH_NAMESPACE"

  # OLM doesn't support dependency resolution on 4.1 yet. Install the operator manually.
  if [[ ${HOSTNAME} = e2e-aws-ocp-41* ]]; then
    install_servicemesh_operator || return 1
  fi

  header "Installing Knative"

  oc new-project $SERVING_NAMESPACE

  # Get the current/latest CSV
  local csv=$(grep currentCSV openshift/olm/knative-serving.catalogsource.yaml | awk '{ print $2 }')
  # Deploy Serverless Operator
  deploy_serverless_operator $csv

  # Deploy KnativeServing CR
  deploy_knativeserving

  wait_until_service_has_external_ip $SERVICEMESH_NAMESPACE istio-ingressgateway || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves "$(kubectl get svc -n $SERVICEMESH_NAMESPACE istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  header "Knative Installed successfully"
}

function deploy_serverless_operator(){
  local csv=$1
  local NAME="serverless-operator"

  # Create imagestream for images generated in CI namespace
  tag_core_images openshift/release/knative-serving-ci.yaml

  # Install CatalogSource in OLM namespace
  oc apply -n $OLM_NAMESPACE -f openshift/olm/knative-serving.catalogsource.yaml
  timeout 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c serverless) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

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
  installPlanApproval: ${INSTALL_PLAN_APPROVAL}
  startingCSV: ${csv}
EOF

  # Approve the initial installplan automatically
  if [ $INSTALL_PLAN_APPROVAL = "Manual" ]; then
    approve_csv $csv
  fi
}

function deploy_knativeserving(){
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

  timeout 900 '[[ $(oc get knativeserving knative-serving -n $SERVING_NAMESPACE -o=jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}") != True ]]'  || return 1
}

function approve_csv()
{
  local csv_version=$1

  # Wait for the installplan to be available
  timeout 900 "[[ -z \$(find_install_plan $csv_version) ]]" || return 1

  local install_plan=$(find_install_plan $csv_version)
  oc get $install_plan -n openshift-operators -o yaml | sed 's/\(.*approved:\) false/\1 true/' | oc replace -f -

  timeout 300 "[[ \$(oc get ClusterServiceVersion $csv_version -n openshift-operators -o jsonpath='{.status.phase}') != Succeeded ]]" || return 1
}

function find_install_plan()
{
  local csv=$1
  for plan in `oc get installplan -n openshift-operators --no-headers -o name`; do 
    [[ $(oc get $plan -n openshift-operators -o=jsonpath='{.spec.clusterServiceVersionNames}' | grep -c $csv) -eq 1 && \
       $(oc get $plan -n openshift-operators -o=jsonpath='{.metadata.ownerReferences[?(@.name=="serverless-operator-subscription")]}') != "" ]] && echo $plan && return 0
  done
  echo ""
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

  rm test/config/100-istio-default-domain.yaml

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
    -v -tags=e2e -count=1 -timeout=35m -short -parallel=3 \
    ./test/e2e \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --resolvabledomain || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=3 \
    ./test/conformance/runtime/... \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --resolvabledomain || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=3 \
    ./test/conformance/api/v1alpha1/... \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --resolvabledomain || failed=1

  return $failed
}

function run_rolling_upgrade_tests() {
    header "Running rolling upgrade tests"

    local TIMEOUT_TESTS="20m"
    failed=0

    report_go_test -tags=preupgrade -timeout=${TIMEOUT_TESTS} ./test/upgrade \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --kubeconfig $KUBECONFIG \
    --resolvabledomain || failed=1

    echo "Starting prober test"

    # Make prober send requests more often compared with upstream where it is 1/second
    sed -e 's/\(.*requestInterval =\).*/\1 200 * time.Millisecond/' -i vendor/knative.dev/pkg/test/spoof/spoof.go

    rm -f /tmp/prober-signal
    report_go_test -tags=probe -timeout=${TIMEOUT_TESTS} ./test/upgrade \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --kubeconfig $KUBECONFIG \
    --resolvabledomain &

    # Wait for the upgrade-probe kservice to be ready before proceeding
    timeout 900 '[[ $(oc get ksvc upgrade-probe -n $TEST_NAMESPACE -o=jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}") != True ]]' || return 1

    # Give routes time to be propagated
    sleep 30

    PROBER_PID=$!
    echo "Prober PID is ${PROBER_PID}"

    if [[ $UPGRADE_SERVERLESS == true ]]; then
      serving_version=$(oc get knativeserving knative-serving -n $SERVING_NAMESPACE -o=jsonpath="{.status.version}")
      # Get the current/latest CSV
      upgrade_to=$(grep currentCSV openshift/olm/knative-serving.catalogsource.yaml | awk '{ print $2 }')
      approve_csv $upgrade_to || return 1

      # Wait for the error to mention ServiceMeshMemberRoll
      timeout 900 '[[ ! ( $(oc get knativeserving knative-serving -n $SERVING_NAMESPACE -o=jsonpath="{.status.conditions[?(@.type==\"Ready\")].reason}") == Error && $(oc get knativeserving knative-serving -n $SERVING_NAMESPACE -o=jsonpath="{.status.conditions[?(@.type==\"Ready\")].message}") =~ SMMR ) ]]' || return 1

      # End the prober test now before we unblock the upgrade, up until now we should have zero failed requests
      end_prober_test ${PROBER_PID}

      # Manual step from the user - clear SMMR in istio-system NS
      oc patch smmr default -n istio-system --type='json' -p='[{"op": "remove", "path": "/spec/members"}]'

      # The knativeserving CR should be updated now
      timeout 900 '[[ ! ( $(oc get knativeserving knative-serving -n $SERVING_NAMESPACE -o=jsonpath="{.status.version}") != $serving_version && $(oc get knativeserving knative-serving -n $SERVING_NAMESPACE -o=jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}") == True ) ]]' || return 1

      # Tests require the correct ingress gateway which is now in a new namespace after upgrade
      export GATEWAY_NAMESPACE_OVERRIDE=knative-serving-ingress
    fi

    # Might not work in OpenShift CI but we want it here so that we can consume this script later and re-use
    if [[ $UPGRADE_CLUSTER == true ]]; then
      end_prober_test ${PROBER_PID}

      latest_cluster_version=$(oc adm upgrade | sed -ne '/VERSION/,$ p' | grep -v VERSION | awk '{print $1}')
      [[ $latest_cluster_version == "" ]] && return 1

      oc adm upgrade --to-latest=true

      timeout 7200 '[[ $(oc get clusterversion -o=jsonpath="{.items[0].status.history[?(@.version==\"${latest_cluster_version}\")].state}") != Completed ]]' || return 1

      echo "New cluster version: $(oc get clusterversion)"
    fi

    for kservice in `oc get ksvc -n $TEST_NAMESPACE --no-headers -o name`; do
      timeout 900 '[[ $(oc get $kservice -n $TEST_NAMESPACE -o=jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}") != True ]]' || return 1
    done

    # Give routes time to be propagated
    sleep 30

    echo "Running postupgrade tests"
    report_go_test -tags=postupgrade -timeout=${TIMEOUT_TESTS} ./test/upgrade \
    --dockerrepo "${INTERNAL_REGISTRY}/${SERVING_NAMESPACE}" \
    --kubeconfig $KUBECONFIG \
    --resolvabledomain || failed=1

    return $failed
}

function end_prober_test(){
  local PROBER_PID=$1
  echo "done" > /tmp/prober-signal
  echo "Waiting for prober test to finish..."
  wait ${PROBER_PID}
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

if [ ${RUN_UPGRADE_TESTS} = true ]; then
  (( !failed )) && install_knative_previous || failed=1
else
  (( !failed )) && install_knative_latest || failed=1
fi

(( !failed )) && create_test_resources_openshift || failed=1

if [ ${RUN_UPGRADE_TESTS} = true ]; then
  (( !failed )) && run_rolling_upgrade_tests || failed=1
fi

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

(( failed )) && dump_openshift_olm_state

(( failed )) && dump_openshift_ingress_state

(( failed )) && exit 1

success
