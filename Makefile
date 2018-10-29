#This makefile is used by ci-operator

.PHONY: test-e2e
test-e2e:
	sh openshift/e2e-tests-openshift.sh
