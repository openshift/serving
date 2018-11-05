#!/bin/sh 

source $(dirname $0)/../test/cluster.sh

set -x

export BUILD_DIR=`pwd`/../build
export PATH=$BUILD_DIR/bin:$BUILD_DIR/google-cloud-sdk/bin:$PATH
export K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
export API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
export USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
export OPENSHIFT_REGISTRY=registry.svc.ci.openshift.org

readonly ISTIO_URL='https://storage.googleapis.com/knative-releases/serving/latest/istio.yaml'
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
  oc adm policy add-cluster-role-to-user cluster-admin -z istio-galley-service-account -n istio-system
  
  # Deploy the latest Istio release
  oc apply -f $ISTIO_URL

  # Ensure the istio-sidecar-injector pod runs as privileged
  oc get cm istio-sidecar-injector -n istio-system -o yaml | sed -e 's/securityContext:/securityContext:\\n      privileged: true/' | oc replace -f -
  # Monitor the Istio components until all the components are up and running
  wait_until_pods_running istio-system || return 1
  header "Istio Installed successfully"
}

function install_knative(){
  header "Installing Knative"
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
  oc apply -f serving-resolved.yaml

  skip_image_tag_resolving
}

function create_test_resources_openshift() {
  echo ">> Creating test resources for OpenShift (test/config/)"
  resolve_resources test/config/ $TEST_NAMESPACE tests-resolved.yaml
  oc apply -f tests-resolved.yaml
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$3
  for yaml in $(find $dir -name "*.yaml"); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)/\1\2 \3\4test-\5/' $yaml | \
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$OPENSHIFT_REGISTRY"'\/'"$OPENSHIFT_BUILD_NAMESPACE"'\/stable:\4/' \
        -e 's/\(.* queueSidecarImage: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$OPENSHIFT_REGISTRY"'\/'"$OPENSHIFT_BUILD_NAMESPACE"'\/stable:\4/' >> $resolved_file_name
  done
}

function enable_docker_schema2(){
  cat > config.yaml <<EOF
  version: 0.1
  log:
    level: debug
  http:
    addr: :5000
  storage:
    cache:
      blobdescriptor: inmemory
    filesystem:
      rootdirectory: /registry
    delete:
      enabled: true
  auth:
    openshift:
      realm: openshift
  middleware:
    registry:
      - name: openshift
    repository:
      - name: openshift
        options:
          acceptschema2: true
          pullthrough: true
          enforcequota: false
          projectcachettl: 1m
          blobrepositorycachettl: 10m
    storage:
      - name: openshift
  openshift:
    version: 1.0
    metrics:
      enabled: false
      secret: <secret>
EOF
  oc project default
  oc create configmap registry-config --from-file=./config.yaml
  oc set volume dc/docker-registry --add --type=configmap --configmap-name=registry-config -m /etc/docker/registry/
  oc set env dc/docker-registry REGISTRY_CONFIGURATION_PATH=/etc/docker/registry/config.yaml
  oc project $TEST_NAMESPACE
}

function skip_image_tag_resolving(){
  oc get cm config-controller -n knative-serving -o yaml | \
  sed -e 's/.*registriesSkippingTagResolving:.*/  registriesSkippingTagResolving: \"ko.local,dev.local,'"$OPENSHIFT_REGISTRY"'\"/' | \
  oc apply -f -
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
    -v -tags=e2e -count=1 -timeout=20m \
    ./test/conformance ./test/e2e \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable \
    ${options} || fail_test
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete --ignore-not-found=true -f ${ISTIO_URL}
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

enable_admission_webhooks

teardown

create_test_namespace

install_istio

enable_docker_schema2

install_knative

create_test_resources_openshift

run_e2e_tests
