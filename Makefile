#This makefile is used by ci-operator

CGO_ENABLED=0
GOOS=linux

install:
	go install ./cmd/activator/ ./cmd/autoscaler/ ./cmd/controller/ ./cmd/queue/ ./cmd/webhook/
.PHONY: install

test-install:
	go build -o $(GOPATH)/bin/test-controller ./test/controller
	go install ./test/test_images/autoscale ./test/test_images/envvars \
	           ./test/test_images/helloworld ./test/test_images/httpproxy \
	           ./test/test_images/pizzaplanetv1 ./test/test_images/pizzaplanetv2
.PHONY: test-install

test-e2e:
	sh openshift/e2e-tests-openshift.sh
.PHONY: test-e2e
