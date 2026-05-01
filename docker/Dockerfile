# =============================================================================
# Custom Cube image — base + your model files + extra Node modules.
#
# Build:
#   docker build -t my-org/cube:1.6.41 \
#     --build-arg CUBE_VERSION=v1.6.41 \
#     -f docker/Dockerfile docker
#
# The image expects model files at docker/schema-example/. Copy your own
# schemas there before building, or mount /cube/conf via the chart's
# schema.configMap or schema.git settings.
# =============================================================================
ARG CUBE_VERSION=v1.6.41
FROM cubejs/cube:${CUBE_VERSION}

# OCI annotations
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="cube-stack"
LABEL org.opencontainers.image.description="Cube.js with bundled model and extra drivers"
LABEL org.opencontainers.image.source="https://github.com/cube-js/cube"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# ---- extra dependencies (drivers, JS deps) ----------------------------------
# Install additional npm packages here. The base image already ships every
# official driver — add only what you need (e.g. custom auth providers,
# driver patches).
WORKDIR /cube/conf
COPY package*.json ./
RUN if [ -f package.json ]; then npm install --omit=dev --no-audit --no-fund; fi

# ---- model / config ---------------------------------------------------------
COPY cube.js ./
COPY model ./model

# Drop privileges back to the upstream non-root user
USER 1000

EXPOSE 4000 15432 13306
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:4000/livez || exit 1

CMD ["cubejs", "server"]
