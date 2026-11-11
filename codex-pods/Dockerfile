# Reuse the existing development tools, with an independently pinned base.
# Codex and its native platform package are installed at build time only.
FROM ghcr.io/christopherscot/claude-pod@sha256:b65061fb6a4ade71124a6a11d4e6e3f96ff06cc7fde31ae818420e157392170a

USER root
ARG CODEX_VERSION=0.167.0
RUN npm install --prefix /opt/codex --no-audit --no-fund "@openai/codex@${CODEX_VERSION}" \
    && /opt/codex/node_modules/.bin/codex --version | grep -qx "codex-cli ${CODEX_VERSION}" \
    && npm cache clean --force
# The home PVC overlays /home/node. Keep executable tools in the image.
ENV PATH="/opt/codex/node_modules/.bin:${PATH}"
COPY tests/image-smoke.sh /usr/local/share/codex-pods/image-smoke.sh
USER node
WORKDIR /workspace
# No idle keepalive inherited from the tooling image.
CMD ["codex", "--version"]
