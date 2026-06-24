# VOC Dev Toolbox
# One image with all CLI tools both teammates need. Run via docker-compose.
FROM debian:bookworm-slim

ARG KUBECTL_VERSION=v1.31.0
ARG K3D_VERSION=v5.7.5
ARG DOCKER_VERSION=27.3.1
ARG HELM_VERSION=v3.16.1
ARG YQ_VERSION=v4.44.5

ENV DEBIAN_FRONTEND=noninteractive \
    KUBECONFIG=/workspace/.kube/config \
    PATH="/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash bash-completion \
      curl wget git openssh-client \
      jq \
      python3 python3-pip python3-venv \
      vim nano less \
      ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# helm
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /tmp && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64

# k3d
RUN curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" \
      -o /usr/local/bin/k3d \
    && chmod +x /usr/local/bin/k3d

# docker CLI (static binary — no daemon, talks to host via socket mount)
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
    | tar -xz -C /tmp && mv /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker

# yq (mikefarah/yq — Go-based, not the Python wrapper)
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
      -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# bash completions
RUN mkdir -p /etc/bash_completion.d \
    && kubectl completion bash > /etc/bash_completion.d/kubectl \
    && helm completion bash > /etc/bash_completion.d/helm

# Copy toolbox scripts
COPY entrypoint.sh /opt/voc/entrypoint.sh
COPY profile.sh    /opt/voc/profile.sh
RUN chmod +x /opt/voc/entrypoint.sh /opt/voc/profile.sh

WORKDIR /workspace

ENTRYPOINT ["/opt/voc/entrypoint.sh"]
CMD ["bash"]
