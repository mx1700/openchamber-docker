FROM node:24-bookworm-slim

ARG OPENCHAMBER_VERSION=latest
ARG OPENCODE_VERSION=

LABEL org.opencontainers.image.title="OpenChamber" \
      org.opencontainers.image.description="OpenChamber Web/Server with a matching OpenCode CLI" \
      org.opencontainers.image.version="${OPENCHAMBER_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bzip2 \
    ca-certificates \
    git \
    less \
    openssh-client \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# @openchamber/web ships the already-built web UI, so there is no frontend build here.
# If OPENCODE_VERSION is not supplied, use the OpenCode version pinned by OpenChamber itself.
# The cleanup keeps only the platform binary copied by OpenCode's postinstall.
RUN set -eux; \
    if [ -z "${OPENCODE_VERSION}" ]; then \
      OPENCODE_VERSION="$(npm view "@openchamber/web@${OPENCHAMBER_VERSION}" dependencies.@opencode/client | tail -n 1)"; \
    fi; \
    test -n "${OPENCODE_VERSION}"; \
    echo "Installing OpenChamber ${OPENCHAMBER_VERSION} with OpenCode ${OPENCODE_VERSION}"; \
    npm install -g --no-fund --no-audit \
      --allow-scripts=@opencode/cli,node-pty \
      "@openchamber/web@${OPENCHAMBER_VERSION}" \
      "@opencode/cli@${OPENCODE_VERSION}"; \
    rm -rf /usr/local/lib/node_modules/@opencode/cli/node_modules; \
    npm cache clean --force

RUN mkdir -p /home/openchamber && chown -R node:node /home/openchamber

USER node
WORKDIR /home/openchamber

ENV NODE_ENV=production \
    HOME=/home/openchamber \
    LANG=C.UTF-8 \
    OPENCHAMBER_HOST=0.0.0.0

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>r.json()).then(j=>process.exit(j.status==='ok'&&j.isOpenCodeReady?0:1)).catch(()=>process.exit(1))"

CMD ["openchamber", "serve", "--foreground", "--host", "0.0.0.0", "--port", "3000"]
