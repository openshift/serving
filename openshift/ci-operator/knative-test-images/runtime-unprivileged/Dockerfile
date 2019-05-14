# Do not edit! This file was generated via Makefile
FROM registry.svc.ci.openshift.org/openshift/origin-v3.11:base

ARG user=test
ARG uid=1000

ARG group=test
ARG gid=1000

RUN groupadd -g ${gid} ${group} && useradd -u ${uid} -g ${gid} -m -s /bin/bash ${user}
USER ${uid}

ADD runtime-unprivileged /usr/bin/runtime-unprivileged
ENTRYPOINT ["/usr/bin/runtime-unprivileged"]
