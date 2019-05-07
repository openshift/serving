
This is the `CatalogSource` for the [knative-serving-operator](https://github.com/openshift-knative/knative-serving-operator).

WARNING: The `knative-serving` operator refers to some Istio CRD's, so:

    kubectl apply -f https://github.com/knative/serving/releases/download/v0.5.1/istio-crds.yaml

To install this `CatalogSource`:

    OLM=$(kubectl get pods --all-namespaces | grep olm-operator | head -1 | awk '{print $1}')
    kubectl apply -n $OLM -f https://raw.githubusercontent.com/openshift/knative-serving/release-v0.5.1/openshift/olm/knative-serving.catalogsource.yaml

To subscribe to it (which will trigger the installation of
knative-serving), either use the console, or apply the following:

	---
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: knative-serving
	---
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: knative-serving
	  namespace: knative-serving
	---
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: knative-serving-operator-sub
	  generateName: knative-serving-operator-
	  namespace: knative-serving
	spec:
	  source: knative-serving-operator
	  sourceNamespace: olm
	  name: knative-serving-operator
	  startingCSV: knative-serving-operator.v0.5.1
	  channel: alpha
