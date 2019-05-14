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
readonly MAISTRA_VERSION="0.10"
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

# Waits until the configmap in the given namespace contains the
# desired content.
# Parameters: $1 - namespace
#             $2 - configmap name
#             $3 - desired content
function wait_until_configmap_contains() {
  echo -n "Waiting until configmap $1/$2 contains '$3'"
  for _ in {1..180}; do  # timeout after 3 minutes
    local output="$(oc -n "$1" get cm "$2" -oyaml | grep "$3")"
    if [[ -n "${output}" ]]; then
      echo -e "\n${output}"
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo -e "\n\nERROR: timeout waiting for configmap $1/$2 to contain '$3'"
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

function patch_istio_for_knative(){
  local sidecar_config=$(oc get configmap -n istio-system istio-sidecar-injector -o yaml)
  if [[ -z "${sidecar_config}" ]]; then
    return 1
  fi
  echo "${sidecar_config}" | grep lifecycle
  if [[ $? -eq 1 ]]; then
    echo "Patching Istio's preStop hook for graceful shutdown"
    echo "${sidecar_config}" | sed 's/\(name: istio-proxy\)/\1\\n    lifecycle:\\n      preStop:\\n        exec:\\n          command: [\\"sh\\", \\"-c\\", \\"sleep 20; while [ $(netstat -plunt | grep tcp | grep -v envoy | wc -l | xargs) -ne 0 ]; do sleep 1; done\\"]/' | oc replace -f -
    oc delete pod -n istio-system -l istio=sidecar-injector
    wait_until_pods_running istio-system || return 1
  fi
  return 0
}

function install_istio(){
  header "Installing Istio"

  # Install the Maistra Operator
  oc new-project istio-operator
  oc new-project istio-system
  oc apply -n istio-operator -f https://raw.githubusercontent.com/Maistra/istio-operator/maistra-${MAISTRA_VERSION}/deploy/maistra-operator.yaml

  # Wait until the Operator pod is up and running
  wait_until_pods_running istio-operator || return 1

  # Deploy Istio
  cat <<EOF | oc apply -f -
apiVersion: istio.openshift.com/v1alpha3
kind: ControlPlane
metadata:
  name: basic-install
spec:
  istio:
    global:
      # use community images
      hub: "maistra"
      tag: ${MAISTRA_VERSION}.0
      proxy:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 128Mi
    gateways:
      istio-egressgateway:
        autoscaleEnabled: false
      istio-ingressgateway:
        autoscaleEnabled: false
        ior_enabled: false
    mixer:
      policy:
        autoscaleEnabled: false
      telemetry:
        autoscaleEnabled: false
        resources:
          requests:
            cpu: 100m
            memory: 1G
          limits:
            cpu: 200m
            memory: 2G
    pilot:
      autoscaleEnabled: false
    kiali:
      enabled: false
    tracing:
      enabled: false
EOF

  timeout 900 '[[ $(oc get ControlPlane/basic-install --template="{{range .status.conditions}}{{printf \"%s=%s, reason=%s, message=%s\n\n\" .type .status .reason .message}}{{end}}" | grep -c Installed=True) -eq 0 ]]' || return 1

  # Scale down unused services deployed by the istio operator. 
  oc scale -n istio-system --replicas=0 deployment/grafana

  patch_istio_for_knative || return 1
  
  header "Istio Installed successfully"
}

function install_knative(){
  header "Installing Knative"

  echo ">> Patching Knative Serving CatalogSource to reference CI produced images"
  CURRENT_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  RELEASE_YAML="https://raw.githubusercontent.com/openshift/knative-serving/${CURRENT_GIT_BRANCH}/openshift/release/knative-serving-ci.yaml"
  sed "s|--filename=.*|--filename=${RELEASE_YAML}|"  openshift/olm/knative-serving.catalogsource.yaml > knative-serving.catalogsource-ci.yaml

  # Install CatalogSources in OLM namespace
  oc apply -n $OLM_NAMESPACE -f knative-serving.catalogsource-ci.yaml
  timeout 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c knative) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  # Install Knative Build
  oc adm policy add-scc-to-user anyuid -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z build-controller -n knative-build
  oc apply -f third_party/config/build/release.yaml

  # Install Tekton Pipeline
  oc adm policy add-scc-to-user anyuid -z build-pipeline-controller -n knative-build-pipeline
  oc adm policy add-cluster-role-to-user cluster-admin -z build-pipeline-controller -n knative-build-pipeline
  oc apply -f third_party/config/pipeline/release.yaml

  # Deploy Knative Operators Serving
  deploy_knative_operator serving

  # Create imagestream for images generated in CI namespace
  tag_core_images openshift/release/knative-serving-ci.yaml

  echo ">> Patching Istio"
  for gateway in istio-ingressgateway cluster-local-gateway istio-egressgateway; do
    if kubectl get svc -n istio-system ${gateway} > /dev/null 2>&1 ; then
      kubectl patch hpa -n istio-system ${gateway} --patch '{"spec": {"maxReplicas": 1}}'
      kubectl set resources deploy -n istio-system ${gateway} \
        -c=istio-proxy --requests=cpu=50m 2> /dev/null
    fi
  done

  # There are reports of Envoy failing (503) when istio-pilot is overloaded.
  # We generously add more pilot instances here to verify if we can reduce flakes.
  if kubectl get hpa -n istio-system istio-pilot 2>/dev/null; then
    # If HPA exists, update it.  Since patching will return non-zero if no change
    # is made, we don't return on failure here.
    kubectl patch hpa -n istio-system istio-pilot \
      --patch '{"spec": {"minReplicas": 3, "maxReplicas": 10, "targetCPUUtilizationPercentage": 60}}' \
      `# Ignore error messages to avoid causing red herrings in the tests` \
      2>/dev/null
  else
    # Some versions of Istio doesn't provide an HPA for pilot.
    kubectl autoscale -n istio-system deploy istio-pilot --min=3 --max=10 --cpu-percent=60 || return 1
  fi

  wait_until_pods_running knative-build || return 1
  wait_until_pods_running knative-build-pipeline || return 1

  # Wait for 6 pods to appear first
  timeout 900 '[[ $(oc get pods -n $SERVING_NAMESPACE --no-headers | wc -l) -lt 6 ]]' || return 1
  wait_until_pods_running knative-serving || return 1

  enable_knative_interaction_with_registry

  wait_until_service_has_external_ip istio-system istio-ingressgateway || fail_test "Ingress has no external IP"

  wait_until_hostname_resolves $(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")

  header "Knative Installed successfully"
}

function deploy_knative_operator(){
  local COMPONENT="knative-$1"

  cat <<-EOF | oc apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: ${COMPONENT}
	EOF
  if oc get crd operatorgroups.operators.coreos.com >/dev/null 2>&1; then
    cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: ${COMPONENT}
	  namespace: ${COMPONENT}
	EOF
  fi
  cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: ${COMPONENT}-subscription
	  generateName: ${COMPONENT}-
	  namespace: ${COMPONENT}
	spec:
	  source: ${COMPONENT}-operator
	  sourceNamespace: $OLM_NAMESPACE
	  name: ${COMPONENT}-operator
	  channel: alpha
	EOF
  cat <<-EOF | oc apply -f -
  apiVersion: serving.knative.dev/v1alpha1
  kind: Install
  metadata:
    name: ${COMPONENT}
    namespace: ${COMPONENT}
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

function enable_knative_interaction_with_registry() {
  local configmap_name=config-service-ca
  local cert_name=service-ca.crt
  local mount_path=/var/run/secrets/kubernetes.io/servicecerts

  oc -n $SERVING_NAMESPACE create configmap $configmap_name
  oc -n $SERVING_NAMESPACE annotate configmap $configmap_name service.alpha.openshift.io/inject-cabundle="true"
  wait_until_configmap_contains $SERVING_NAMESPACE $configmap_name $cert_name
  oc -n $SERVING_NAMESPACE set volume deployment/controller --add --name=service-ca --configmap-name=$configmap_name --mount-path=$mount_path
  oc -n $SERVING_NAMESPACE set env deployment/controller SSL_CERT_FILE=$mount_path/$cert_name
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
}

function run_e2e_tests(){
  header "Running tests"
  options=""
  (( EMIT_METRICS )) && options="-emitmetrics"
  failed=0

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -short -parallel=1 \
    ./test/e2e \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${SERVING_NAMESPACE} \
    ${options} || failed=1

  report_go_test \
    -v -tags=e2e -count=1 -timeout=35m -parallel=1 \
    ./test/conformance \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${SERVING_NAMESPACE} \
    ${options} || failed=1

  return $failed
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete ControlPlane/basic-install -n istio-system
}

function delete_knative_openshift() {
  echo ">> Bringing down Knative Serving, Build and Pipeline"
  oc delete --ignore-not-found=true -n $OLM_NAMESPACE -f knative-serving.catalogsource-ci.yaml
  oc delete --ignore-not-found=true -f third_party/config/build/release.yaml
  oc delete --ignore-not-found=true -f third_party/config/pipeline/release.yaml

  oc delete project $SERVING_NAMESPACE
  oc delete project knative-build
  oc delete project knative-build-pipeline
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
  delete_istio_openshift
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

install_istio || failed=1

(( !failed )) && install_knative || failed=1

(( !failed )) && create_test_resources_openshift || failed=1

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success
