# Dockerfile to bootstrap build and test in openshift-ci

FROM openshift/origin-release:golang-1.10

# Add Google Cloud SDK repository
ADD google-cloud-sdk.repo /etc/yum.repos.d/

# Add kubernetes repository
ADD kubernetes.repo /etc/yum.repos.d/

RUN yum install -y google-cloud-sdk kubectl ansible && \
    go get github.com/google/go-containerregistry/cmd/ko
