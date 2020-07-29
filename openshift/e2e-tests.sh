#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/e2e-common.sh"

set -x

env

echo "mutatingwebhookconfigurations"
oc get mutatingwebhookconfigurations  --all-namespaces  -o yaml
echo ""

echo "validatingwebhookconfigurations"
oc get validatingwebhookconfigurations  --all-namespaces  -o yaml

exit 1

scale_up_workers || exit $?

failed=0

(( !failed )) && install_knative || failed=1
(( !failed )) && prepare_knative_serving_tests || failed=2
(( !failed )) && run_e2e_tests || failed=3
(( failed )) && exit $failed

success
