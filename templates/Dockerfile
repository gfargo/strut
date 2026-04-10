# ==================================================
# Multi-stage Python 3.11 build template
# ==================================================
# Replace PACKAGE_NAME with your module name
# Replace ENTRY_POINT with your app entry point (e.g. my_app.main:app)
# ARG GH_TOKEN is used to install private packages from GitHub

ARG PYTHON_VERSION=3.11

# ── Stage 1: build dependencies ───────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim AS builder

WORKDIR /build

# Accept GH_TOKEN for private package installs (never cached in final image)
ARG GH_TOKEN
ENV GH_TOKEN=${GH_TOKEN}

# Install build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies with pip cache mount (faster rebuilds)
COPY pyproject.toml ./
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip && \
    pip install --prefix=/install .

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim AS runtime

WORKDIR /app

# Install only runtime system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

# Copy application source
COPY src/ ./src/

# Copy entrypoint
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["docker-entrypoint.sh"]
# Replace with your actual entry point:
CMD ["uvicorn", "PACKAGE_NAME.main:app", "--host", "0.0.0.0", "--port", "8000"]
