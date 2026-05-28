# syntax=docker/dockerfile:1.7
# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — fetch DepotDownloader.
# Cached separately from the runtime stage so script changes don't refetch.
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS depot

ARG DEPOT_DOWNLOADER_VERSION=3.4.0
ARG DEPOT_DOWNLOADER_URL="https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOT_DOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip"

# pipefail so a truncated `curl | tar/unzip` fails loudly — hadolint DL4006.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates unzip

RUN mkdir -p /opt/depotdownloader && \
    curl -sSfL "${DEPOT_DOWNLOADER_URL}" -o /tmp/dd.zip && \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader && \
    chmod +x /opt/depotdownloader/DepotDownloader && \
    rm /tmp/dd.zip

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — runtime.
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

ARG DOTNET_CHANNEL=8.0
ARG DOTNET_INSTALL_URL="https://dot.net/v1/dotnet-install.sh"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/mnt/steam \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/usr/share/dotnet:/home/steam/server:${PATH}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime deps:
#   tini             — PID 1, signal forwarding, zombie reaping
#   ca-certificates  — TLS roots for steam + DepotDownloader
#   curl, unzip      — pulled in for ad-hoc operator use inside the container
#   libicu74         — .NET 8 requires ICU for globalization
#   gettext-base     — `envsubst`, used for future template rendering
#   procps           — `pgrep` for healthcheck / lifecycle scripts
#   python3-minimal  — A2S healthcheck probe (pure stdlib)
#   tar, gzip        — backup tarballs
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        tini \
        ca-certificates \
        curl \
        unzip \
        libicu74 \
        gettext-base \
        procps \
        python3-minimal \
        tar \
        gzip

# Ubuntu 24.04 ships a default `ubuntu` user at UID 1000 — remove it first so
# we can claim 1000:1001 (the Steam-server-on-Docker convention; see
# blueprint/README.md → UID/GID).
RUN userdel --remove ubuntu 2>/dev/null || true && \
    groupadd --gid 1001 steam && \
    useradd  --uid 1000 --gid 1001 --shell /bin/bash --create-home --home-dir /mnt/steam steam && \
    mkdir -p /mnt/steam/server-files /mnt/steam/backups && \
    chown -R steam:steam /mnt/steam

# Install .NET 8 runtime via the official installer script (apt's dotnet
# tracks an older channel and conflicts with Microsoft's package feed).
RUN curl -sSfL "${DOTNET_INSTALL_URL}" -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --runtime dotnet --install-dir /usr/share/dotnet && \
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet && \
    rm /tmp/dotnet-install.sh

# DepotDownloader binary (pre-fetched in stage 1).
COPY --from=depot /opt/depotdownloader /opt/depotdownloader
RUN ln -sf /opt/depotdownloader/DepotDownloader /usr/local/bin/DepotDownloader

# Scripts + baked defaults.
COPY --chmod=0755 scripts/   /home/steam/server/
COPY --chmod=0644 config/    /home/steam/server/config/
COPY --chmod=0755 docker/healthcheck.py /opt/healthcheck.py

# Symlink the CLI entrypoint into PATH so operators can `docker exec server rs ...`.
RUN ln -sf /home/steam/server/rs /usr/local/bin/rs

# Canonical mount point — matches blueprint convention and K8s manifests.
VOLUME ["/mnt/steam"]

EXPOSE 8050/udp

USER steam
WORKDIR /mnt/steam

# A2S probe over UDP 8050. start_period in compose covers cold boot;
# 30 s timeout here is for steady-state liveness.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD python3 /opt/healthcheck.py || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "rs"]
CMD ["run"]
