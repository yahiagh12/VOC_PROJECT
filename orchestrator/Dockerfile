FROM alpine:3.20

# Install dependencies needed by scan-all.sh:
# bash, curl, jq, and kubectl
RUN apk add --no-cache bash curl jq python3 && \
    curl -LO "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

WORKDIR /workspace

# Copy the scanner templates and scripts
COPY scanners/ /workspace/scanners/
COPY scripts/ /workspace/scripts/

# Make the orchestrator script executable
RUN chmod +x /workspace/scripts/scan-all.sh

CMD ["/workspace/scripts/scan-all.sh"]
