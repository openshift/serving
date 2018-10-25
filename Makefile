#This makefile is used by ci-operator

BUILD_DIR=$(shell pwd)/build
GCLOUD_URL=https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-222.0.0-linux-x86_64.tar.gz
GCLOUD_ARCHIVE=$(shell echo $(GCLOUD_URL) | rev | cut -d/ -f1 | rev)
KUBECTL_URL=https://storage.googleapis.com/kubernetes-release/release/v1.11.0/bin/linux/amd64/kubectl

#TODO: Move this to a builder image in CI
.PHONY: init
init:
	@echo "Downloading gcloud"
	@mkdir -p $(BUILD_DIR)/bin
	@cd $(BUILD_DIR) && \
	curl -LO --progress-bar $(GCLOUD_URL) && tar xzf $(GCLOUD_ARCHIVE)
	@echo "Downloading kubectl"
	@cd $(BUILD_DIR)/bin && \
	curl -LO --progress-bar $(KUBECTL_URL) && chmod +x ./kubectl
	@echo "Downloading ko"
	go get github.com/google/go-containerregistry/cmd/ko
	@echo "Done preparing environment"

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)

.PHONY: test-e2e
test-e2e: init
	sh test/e2e-tests-openshift.sh
