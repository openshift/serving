#!/usr/bin/env bash

source $(dirname $0)/../test/e2e-common.sh

set -x

readonly ENABLE_ADMISSION_WEBHOOKS="${ENABLE_ADMISSION_WEBHOOKS:-"true"}"
readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-"docker-registry.default.svc:5000"}"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-"$HOME/.ssh/google_compute_engine"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly MAISTRA_VERSION="0.6"
readonly TEST_NAMESPACE=serving-tests
readonly SERVING_NAMESPACE=knative-serving

env

function enable_admission_webhooks(){
  header "Enabling admission webhooks"
  add_current_user_to_etc_passwd
  disable_strict_host_checking
  echo "API_SERVER=$API_SERVER"
  echo "KUBE_SSH_USER=$KUBE_SSH_USER"
  chmod 600 $SSH_PRIVATE_KEY
  echo "$API_SERVER ansible_ssh_private_key_file=${SSH_PRIVATE_KEY}" > inventory.ini
  ansible-playbook ${REPO_ROOT_DIR}/openshift/admission-webhooks.yaml -i inventory.ini -u $KUBE_SSH_USER
  rm inventory.ini
}

function add_current_user_to_etc_passwd(){
  if ! whoami &>/dev/null; then
    echo "${USER:-default}:x:$(id -u):$(id -g):Default User:$HOME:/sbin/nologin" >> /etc/passwd
  fi
  cat /etc/passwd
}

function disable_strict_host_checking(){
  cat >> ~/.ssh/config <<EOF
Host *
   StrictHostKeyChecking no
   UserKnownHostsFile=/dev/null
EOF
}

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"
  # Get the name of the first machineset that has at least 1 replica
  local machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" -l machine.openshift.io/cluster-api-machine-type=worker | grep " 1" | head -n 1 | awk '{print $1}')
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
  oc create namespace istio-operator
  oc process -f https://raw.githubusercontent.com/Maistra/openshift-ansible/maistra-${MAISTRA_VERSION}/istio/istio_community_operator_template.yaml | oc create -f -

  # Wait until the Operator pod is up and running
  wait_until_pods_running istio-operator || return 1

  # Deploy Istio
  cat <<EOF | oc apply -f -
apiVersion: istio.openshift.com/v1alpha1
kind: Installation
metadata:
  namespace: istio-operator
  name: istio-installation
spec:
  istio:
    authentication: false
    community: true
EOF

  # Wait until at least the istio installer job is running
  wait_until_pods_running istio-system || return 1

  timeout 900 'oc get pods -n istio-system && [[ $(oc get pods -n istio-system | grep openshift-ansible-istio-installer | grep -c Completed) -eq 0 ]]' || return 1

  # Scale down unused services deployed by the istio operator. The
  # jaeger pods will fail anyway due to the elasticsearch pod failing
  # due to "max virtual memory areas vm.max_map_count [65530] is too
  # low, increase to at least [262144]" which could be mitigated on
  # minishift with:
  #  minishift ssh "echo 'echo vm.max_map_count = 262144 >/etc/sysctl.d/99-elasticsearch.conf' | sudo sh"
  oc scale -n istio-system --replicas=0 deployment/grafana
  oc scale -n istio-system --replicas=0 deployment/jaeger-collector
  oc scale -n istio-system --replicas=0 deployment/jaeger-query
  oc scale -n istio-system --replicas=0 statefulset/elasticsearch

  patch_istio_for_knative || return 1
  
  header "Istio Installed successfully"
}

function install_knative(){
  header "Installing Knative"

  # Create knative-serving namespace, needed for imagestreams
  oc create namespace $SERVING_NAMESPACE

  # Grant the necessary privileges to the service accounts Knative will use:
  oc adm policy add-scc-to-user anyuid -z build-controller -n knative-build
  oc adm policy add-scc-to-user anyuid -z controller -n knative-serving
  oc adm policy add-scc-to-user anyuid -z autoscaler -n knative-serving
  oc adm policy add-cluster-role-to-user cluster-admin -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z controller -n knative-serving

  oc adm policy add-scc-to-user anyuid -z build-pipeline-controller -n knative-build-pipeline
  oc adm policy add-cluster-role-to-user cluster-admin -z build-pipeline-controller -n knative-build-pipeline

  # Deploy Knative Serving from the current source repository. This will also install Knative Build.
  create_serving_and_build
  enable_knative_interaction_with_registry

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
  wait_until_pods_running knative-serving || return 1
  wait_until_service_has_external_ip istio-system istio-ingressgateway || fail_test "Ingress has no external IP"

  wait_until_hostname_resolves $(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")

  header "Knative Installed successfully"
}

function create_serving_and_build(){
  echo ">> Bringing up Build and Serving"
  oc apply -f third_party/config/build/release.yaml
  oc apply -f third_party/config/pipeline/release.yaml
  
  > serving-resolved.yaml
  resolve_resources config/ $SERVING_NAMESPACE serving-resolved.yaml
  
  # Remove nodePort spec as the ports do not fall into the range allowed by OpenShift
  sed '/nodePort/d' serving-resolved.yaml | oc apply -f -
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

  > tests-resolved.yaml
  resolve_resources test/config/ $TEST_NAMESPACE tests-resolved.yaml
  
  oc apply -f tests-resolved.yaml

  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts:${TEST_NAMESPACE} --namespace=${SERVING_NAMESPACE}
  oc policy add-role-to-group system:image-puller system:serviceaccounts:knative-testing --namespace=${SERVING_NAMESPACE}

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$3
  for yaml in $(find $dir -name "*.yaml" -mindepth 1 -maxdepth 1); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)/\1\2 \3\4test-\5/' $yaml | \
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$SERVING_NAMESPACE"'\/knative-serving-\4/' \
        -e 's/\(.* queueSidecarImage: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$SERVING_NAMESPACE"'\/knative-serving-\4/' >> $resolved_file_name
  done

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${SERVING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name}
  done
}

function create_test_namespace(){
  oc new-project $TEST_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE
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
  oc delete --ignore-not-found=true -f $ISTIO_YAML
  oc delete --ignore-not-found=true -f $ISTIO_CRD_YAML
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f serving-resolved.yaml
  oc delete --ignore-not-found=true -f third_party/config/build/release.yaml
  oc delete --ignore-not-found=true -f third_party/config/pipeline/release.yaml
}

function delete_test_resources_openshift() {
  echo ">> Removing test resources (test/config/)"
  oc delete --ignore-not-found=true -f tests-resolved.yaml
}

function delete_test_namespace(){
  echo ">> Deleting test namespace $TEST_NAMESPACE"
  oc delete project $TEST_NAMESPACE
}

function teardown() {
  delete_test_namespace
  delete_test_resources_openshift
  delete_serving_openshift
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

if [[ $ENABLE_ADMISSION_WEBHOOKS == "true" ]]; then
  enable_admission_webhooks
fi

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
