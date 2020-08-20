#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/../test/e2e-common.sh"
source "$(dirname "$0")/release/resolve.sh"

readonly SERVING_NAMESPACE=knative-serving
readonly SERVING_INGRESS_NAMESPACE=knative-serving-ingress

# The OLM global namespace was moved to openshift-marketplace since v4.2
# ref: https://jira.coreos.com/browse/OLM-1190
readonly OLM_NAMESPACE="openshift-marketplace"

# Determine if we're running locally or in CI.
if [ -n "$OPENSHIFT_BUILD_NAMESPACE" ]; then
  readonly TEST_IMAGE_TEMPLATE="${IMAGE_FORMAT//\$\{component\}/knative-serving-test-{{.Name}}}"
elif [ -n "$DOCKER_REPO_OVERRIDE" ]; then
  readonly TEST_IMAGE_TEMPLATE="${DOCKER_REPO_OVERRIDE}/{{.Name}}"
elif [ -n "$BRANCH" ]; then
  readonly TEST_IMAGE_TEMPLATE="registry.svc.ci.openshift.org/openshift/${BRANCH}:knative-serving-test-{{.Name}}"
elif [ -n "$TEMPLATE" ]; then
  readonly TEST_IMAGE_TEMPLATE="$TEMPLATE"
else
  readonly TEST_IMAGE_TEMPLATE="registry.svc.ci.openshift.org/openshift/knative-nightly:knative-serving-test-{{.Name}}"
fi

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

  CATALOG_SOURCE="openshift/olm/knative-serving.catalogsource.yaml"

  # Install CatalogSource in OLM namespace
  # TODO: Rework this into a loop
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-queue|${IMAGE_FORMAT//\$\{component\}/knative-serving-queue}|g"                   ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-activator|${IMAGE_FORMAT//\$\{component\}/knative-serving-activator}|g"           ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-autoscaler|${IMAGE_FORMAT//\$\{component\}/knative-serving-autoscaler}|g"         ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-autoscaler-hpa|${IMAGE_FORMAT//\$\{component\}/knative-serving-autoscaler-hpa}|g" ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-controller|${IMAGE_FORMAT//\$\{component\}/knative-serving-controller}|g"         ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-webhook|${IMAGE_FORMAT//\$\{component\}/knative-serving-webhook}|g"               ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-serving-storage-version-migration|${IMAGE_FORMAT//\$\{component\}/knative-serving-storage-version-migration}|g" ${CATALOG_SOURCE}

  # Replace kourier's image with the latest ones from third_party/kourier-latest
  KOURIER_CONTROL=$(grep -w "gcr.io/knative-nightly/knative.dev/net-kourier/cmd/kourier" third_party/kourier-latest/kourier.yaml  | awk '{print $NF}')
  KOURIER_GATEWAY=$(grep -w "docker.io/maistra/proxyv2-ubi8" third_party/kourier-latest/kourier.yaml  | awk '{print $NF}')

  # Add these variable manually until operator implements it. See SRVKS-610
  sed -i -e 's/value: "kourier-system"/value: "knative-serving-ingress"/g'  third_party/kourier-latest/kourier.yaml
  sed -i -e 's/kourier-control.knative-serving/kourier-control.knative-serving-ingress/g'  third_party/kourier-latest/kourier.yaml

  sed -i -e "s|docker.io/maistra/proxyv2-ubi8:.*|${KOURIER_GATEWAY}|g"                                         ${CATALOG_SOURCE}
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:kourier|${KOURIER_CONTROL}|g"               ${CATALOG_SOURCE}

  # release-next branch keeps updating the latest manifest in knative-serving-ci.yaml for serving resources.
  # see: https://github.com/openshift/knative-serving/blob/release-next/openshift/release/knative-serving-ci.yaml
  # So mount the manifest and use it by KO_DATA_PATH env value.
  patch -u ${CATALOG_SOURCE} < openshift/olm/config_map.patch

  oc apply -n $OLM_NAMESPACE -f ${CATALOG_SOURCE}
  timeout 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c serverless) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  # Deploy Serverless Operator
  deploy_serverless_operator

  # Wait for the CRD to appear
  timeout 900 '[[ $(oc get crd | grep -c knativeservings) -eq 0 ]]' || return 1

  # Install Knative Serving with initial values in test/config/config-observability.yaml.
  cat <<-EOF | oc apply -f -
apiVersion: operator.knative.dev/v1alpha1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: ${SERVING_NAMESPACE}
spec:
  config:
    observability:
      logging.request-log-template: '{"httpRequest": {"requestMethod": "{{.Request.Method}}",
        "requestUrl": "{{js .Request.RequestURI}}", "requestSize": "{{.Request.ContentLength}}",
        "status": {{.Response.Code}}, "responseSize": "{{.Response.Size}}", "userAgent":
        "{{js .Request.UserAgent}}", "remoteIp": "{{js .Request.RemoteAddr}}", "serverIp":
        "{{.Revision.PodIP}}", "referer": "{{js .Request.Referer}}", "latency": "{{.Response.Latency}}s",
        "protocol": "{{.Request.Proto}}"}, "traceId": "{{index .Request.Header "X-B3-Traceid"}}"}'
      logging.enable-probe-request-log: "true"
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

  # Create configmap to use the latest kourier.
  oc create configmap kourier-cm -n $operator_ns --from-file="third_party/kourier-latest/kourier.yaml"

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
  channel: "preview-4.6"
EOF
}

function prepare_knative_serving_tests {
  echo ">> Creating test resources for OpenShift (test/config/)"

  oc apply -f test/config

  oc adm policy add-scc-to-user privileged -z default -n serving-tests
  oc adm policy add-scc-to-user privileged -z default -n serving-tests-alt
  # Adding scc for anyuid to test TestShouldRunAsUserContainerDefault.
  oc adm policy add-scc-to-user anyuid -z default -n serving-tests

  export SYSTEM_NAMESPACE="$SERVING_NAMESPACE"
  export GATEWAY_OVERRIDE=kourier
  export GATEWAY_NAMESPACE_OVERRIDE="$SERVING_INGRESS_NAMESPACE"
  export INGRESS_CLASS=kourier.ingress.networking.knative.dev
}

function run_e2e_tests(){
  header "Running tests"

  local test_name=$1 
  local failed=0

  # Keep this in sync with test/ha/ha.go
  readonly OPENSHIFT_REPLICAS=2
  # TODO: Increase BUCKETS size more than 1 when operator supports configmap/config-leader-election setting.
  readonly OPENSHIFT_BUCKETS=1

  # Changing the bucket count and cycling the controllers will leave around stale
  # lease resources at the old sharding factor, so clean these up.
  kubectl -n ${SYSTEM_NAMESPACE} delete leases --all

  # Wait for a new leader Controller to prevent race conditions during service reconciliation
  wait_for_leader_controller || failed=1

  # Dump the leases post-setup.
  header "Leaders"
  kubectl get lease -n "${SYSTEM_NAMESPACE}"

  # Enable allow-zero-initial-scale before running e2e tests (for test/e2e/initial_scale_test.go)
  oc -n ${SYSTEM_NAMESPACE} patch knativeserving/knative-serving --type=merge --patch='{"spec": {"config": { "autoscaler": {"allow-zero-initial-scale": "true"}}}}' || fail_test

  # Give the controller time to sync with the rest of the system components.
  sleep 30

  if [ -n "$test_name" ]; then
    go_test_e2e -tags=e2e -timeout=15m -parallel=1 \
    ./test/e2e ./test/conformance/api/... ./test/conformance/runtime/... \
    -run "^(${test_name})$" \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain "$(ingress_class)" || failed=$?

    return $failed
  fi

  local parallel=3

  if [[ $(oc get infrastructure cluster -ojsonpath='{.status.platform}') = VSphere ]]; then
    # Since we don't have LoadBalancers working, gRPC tests will always fail.
    rm ./test/e2e/grpc_test.go
    parallel=2
  fi

  go_test_e2e -tags=e2e -timeout=30m -parallel=$parallel \
    ./test/e2e ./test/conformance/api/... ./test/conformance/runtime/... \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain "$(ingress_class)" || failed=1

 # Run the helloworld test with an image pulled into the internal registry.
  local image_to_tag=$(echo "$TEST_IMAGE_TEMPLATE" | sed 's/\(.*\){{.Name}}\(.*\)/\1helloworld\2/')
  oc tag -n serving-tests "$image_to_tag" "helloworld:latest" --reference-policy=local
  go_test_e2e -tags=e2e -timeout=30m ./test/e2e -run "^(TestHelloWorld)$" \
    --resolvabledomain --kubeconfig "$KUBECONFIG" \
    --imagetemplate "image-registry.openshift-image-registry.svc:5000/serving-tests/{{.Name}}" || failed=2

  # Prevent HPA from scaling to make the tests more stable
  oc -n "$SERVING_NAMESPACE" patch hpa activator \
  --type 'merge' \
  --patch '{"spec": {"maxReplicas": '${OPENSHIFT_REPLICAS}', "minReplicas": '${OPENSHIFT_REPLICAS}'}}' || return 1

  # Use sed as the -spoofinterval parameter is not available yet
  sed "s/\(.*requestInterval =\).*/\1 10 * time.Millisecond/" -i vendor/knative.dev/pkg/test/spoof/spoof.go

  # Run HA tests separately as they're stopping core Knative Serving pods
  # Define short -spoofinterval to ensure frequent probing while stopping pods
  go_test_e2e -tags=e2e -timeout=15m -failfast -parallel=1 \
    ./test/ha \
    -replicas="${OPENSHIFT_REPLICAS}" -buckets="${OPENSHIFT_BUCKETS}" -spoofinterval="10ms" \
    --kubeconfig "$KUBECONFIG" \
    --imagetemplate "$TEST_IMAGE_TEMPLATE" \
    --resolvabledomain "$(ingress_class)"|| failed=3

  return $failed
}

function gather_knative_state {
  logger.info 'Gather knative state'
  local gather_dir="${ARTIFACT_DIR:-/tmp}/gather-knative"
  mkdir -p "$gather_dir"

  oc --insecure-skip-tls-verify adm must-gather \
    --image=quay.io/openshift-knative/must-gather \
    --dest-dir "$gather_dir" > "${gather_dir}/gather-knative.log"
}
