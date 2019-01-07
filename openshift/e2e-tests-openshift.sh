#!/bin/sh 

source $(dirname $0)/../test/cluster.sh

set -x

export BUILD_DIR=`pwd`/../build
export PATH=$BUILD_DIR/bin:$BUILD_DIR/google-cloud-sdk/bin:$PATH
export K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
export API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
export INTERNAL_REGISTRY="docker-registry.default.svc:5000"
export USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
export OPENSHIFT_REGISTRY=registry.svc.ci.openshift.org

readonly ISTIO_YAML=$(find third_party -mindepth 1 -maxdepth 1 -type d -name "istio-*")/istio.yaml
readonly TEST_NAMESPACE=serving-tests
readonly SERVING_NAMESPACE=knative-serving

env

function enable_admission_webhooks(){
  header "Enabling admission webhooks"
  add_current_user_to_etc_passwd
  disable_strict_host_checking
  echo "API_SERVER=$API_SERVER"
  echo "KUBE_SSH_USER=$KUBE_SSH_USER"
  chmod 600 ~/.ssh/google_compute_engine
  echo "$API_SERVER ansible_ssh_private_key_file=~/.ssh/google_compute_engine" > inventory.ini
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

function install_istio(){
  header "Installing Istio"
  # Grant the necessary privileges to the service accounts Istio will use:
  oc adm policy add-scc-to-user anyuid -z istio-ingress-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z default -n istio-system
  oc adm policy add-scc-to-user anyuid -z prometheus -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-egressgateway-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-citadel-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-cleanup-old-ca-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-mixer-post-install-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-mixer-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-pilot-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-sidecar-injector-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z cluster-local-gateway-service-account -n istio-system
  oc adm policy add-cluster-role-to-user cluster-admin -z istio-galley-service-account -n istio-system
  
  # Deploy the latest Istio release
  oc apply -f $ISTIO_YAML

  # Ensure the istio-sidecar-injector pod runs as privileged
  oc get cm istio-sidecar-injector -n istio-system -o yaml | sed -e 's/securityContext:/securityContext:\\n      privileged: true/' | oc replace -f -
  # Monitor the Istio components until all the components are up and running
  wait_until_pods_running istio-system || return 1
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

  # Deploy Knative Serving from the current source repository. This will also install Knative Build.
  create_serving_and_build

  echo ">> Patching Istio"
  oc patch hpa -n istio-system knative-ingressgateway --patch '{"spec": {"maxReplicas": 1}}'

  wait_until_pods_running knative-build || return 1
  wait_until_pods_running knative-serving || return 1
  wait_until_service_has_external_ip istio-system knative-ingressgateway || fail_test "Ingress has no external IP"
  header "Knative Installed successfully"
}

function create_serving_and_build(){
  echo ">> Bringing up Build and Serving"
  oc apply -f third_party/config/build/release.yaml
  
  resolve_resources config/ $SERVING_NAMESPACE serving-resolved.yaml
  
  # Remove nodePort spec as the ports do not fall into the range allowed by OpenShift
  sed '/nodePort/d' serving-resolved.yaml | oc apply -f -

  echo ">>> Setting SSL_CERT_FILE for Knative Serving Controller"
  oc set env -n knative-serving deployment/controller SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
}

function create_test_resources_openshift() {
  echo ">> Creating test resources for OpenShift (test/config/)"
  resolve_resources test/config/ $TEST_NAMESPACE tests-resolved.yaml
  oc apply -f tests-resolved.yaml

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images

  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts:${TEST_NAMESPACE} --namespace=${SERVING_NAMESPACE}
  oc policy add-role-to-group system:image-puller system:serviceaccounts:knative-testing --namespace=${SERVING_NAMESPACE}
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$3
  for yaml in $(find $dir -name "*.yaml"); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)/\1\2 \3\4test-\5/' $yaml | \
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$SERVING_NAMESPACE"'\/knative-serving-\4/' \
        -e 's/\(.* queueSidecarImage: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$SERVING_NAMESPACE"'\/knative-serving-\4/' >> $resolved_file_name
  done

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name}
  done
}

function enable_docker_schema2(){
  oc set env -n default dc/docker-registry REGISTRY_MIDDLEWARE_REPOSITORY_OPENSHIFT_ACCEPTSCHEMA2=true
}

function create_test_namespace(){
  oc new-project $TEST_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE
}

function run_e2e_tests(){
  header "Running tests"
  options=""
  (( EMIT_METRICS )) && options="-emitmetrics"
  report_go_test \
    -v -tags=e2e -count=1 -timeout=30m \
    ./test/conformance ./test/e2e \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${SERVING_NAMESPACE} \
    ${options} || return 1
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete --ignore-not-found=true -f $ISTIO_YAML
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f serving-resolved.yaml
  oc delete --ignore-not-found=true -f third_party/config/build/release.yaml
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
  oc tag -n ${SERVING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:knative-serving-test-helloworld invalidhelloworld:not_latest
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  oc tag -n ${SERVING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:latest
}

enable_admission_webhooks

create_test_namespace

install_istio

enable_docker_schema2

install_knative

create_test_resources_openshift

failed=0

run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success
