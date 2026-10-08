# syntax=docker/dockerfile:1.28

# Multi-app build: a shared `base` stage (KasmVNC + X + pulseaudio + generic
# entrypoint) with one final stage per emulator, published as separate images.
#   docker build --target amiberry       -t amiberry:local .
#   docker build --target copperline-vnc -t copperline-vnc:local .
# (The image is named copperline-vnc because plain ghcr.io/sidick/copperline
# is taken by the browser/WASM build published from the copperline-docker
# repo; this one is the native app over KasmVNC.)
# The amiberry stage is deliberately last so a bare `docker build .` still
# produces the amiberry image, as it did before this repo went multi-app.

########################################################################
# base — everything the app images share
########################################################################
FROM debian:trixie-slim AS base

ARG TARGETARCH
ARG KASMVNC_VERSION=1.4.0

LABEL org.opencontainers.image.source="https://github.com/sidick/amiga-emulation-docker" \
      org.opencontainers.image.url="https://github.com/sidick/amiga-emulation-docker" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-slim"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/config \
    USER=app \
    DISPLAY=:1 \
    VNC_PORT=8443 \
    VNC_GEOMETRY=1280x960 \
    VNC_DEPTH=24 \
    PULSE_SERVER=unix:/tmp/pulse-socket

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip \
        tini \
        pulseaudio pulseaudio-utils \
        xauth xfonts-base xfonts-100dpi xfonts-75dpi \
        libxfont2 libpixman-1-0 libxkbcommon0 libxshmfence1 \
        dbus-x11 \
        ssl-cert \
    && make-ssl-cert generate-default-snakeoil --force-overwrite \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) arch=amd64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/kasmvnc.deb \
        "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_trixie_${KASMVNC_VERSION}_${arch}.deb"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/kasmvnc.deb; \
    rm -f /tmp/kasmvnc.deb; \
    rm -rf /var/lib/apt/lists/*

RUN useradd -u 1000 -s /bin/bash -d /config -M -G ssl-cert,audio,video app \
    && mkdir -p /config \
    && chown -R app:app /config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/config"]
EXPOSE 8443

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

########################################################################
# copperline-vnc — Copperline built from source (upstream distributes source,
# Flatpak and AppImage only), then dropped onto the shared base
########################################################################
FROM rust:1-trixie AS copperline-build

ARG COPPERLINE_VERSION=0.12.0

# alsa + udev dev packages are cpal's and gilrs' native build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
        libasound2-dev libudev-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "v${COPPERLINE_VERSION}" \
        https://github.com/LinuxJedi/Copperline /src
WORKDIR /src
RUN cargo build --release

FROM base AS copperline-vnc

ARG COPPERLINE_VERSION=0.12.0

LABEL org.opencontainers.image.title="copperline-vnc" \
      org.opencontainers.image.description="Copperline Amiga emulator with KasmVNC web access" \
      org.opencontainers.image.version="${COPPERLINE_VERSION}"

ENV VNC_USER=copperline \
    APP_LOG=/config/copperline.log

# Copperline presents via wgpu's Vulkan backend; in the GPU-less Xvnc session
# that means mesa's lavapipe software driver. Audio goes cpal -> ALSA -> pulse
# plugin (see asound.conf), and gilrs wants libudev for gamepad discovery.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libvulkan1 mesa-vulkan-drivers \
        libasound2-plugins libudev1 \
        libx11-6 libxcursor1 libxrandr2 libxi6 libxkbcommon-x11-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=copperline-build /src/target/release/copperline /usr/bin/copperline
# The bundled AROS boot ROM is not embedded in the binary: romsearch.rs looks
# for it under <prefix>/share/copperline/aros relative to the binary, the same
# layout upstream's AppImage uses. Without it copperline exits at startup
# unless the user supplies their own Kickstart ROM.
COPY --from=copperline-build \
    /src/assets/aros/aros-amiga-m68k-rom.bin \
    /src/assets/aros/aros-amiga-m68k-ext.bin \
    /src/assets/aros/LICENSE \
    /usr/share/copperline/aros/
COPY apps/copperline-vnc/asound.conf /etc/asound.conf
COPY apps/copperline-vnc/copperline.toml /opt/app-seed/copperline.toml
COPY apps/copperline-vnc/app-init.sh /usr/local/lib/app-init.sh
COPY apps/copperline-vnc/start-app /usr/local/bin/start-app
RUN chmod +x /usr/local/bin/start-app

########################################################################
# amiberry — upstream release .deb on the shared base
########################################################################
FROM base AS amiberry

ARG TARGETARCH
ARG AMIBERRY_VERSION=8.2.2

LABEL org.opencontainers.image.title="amiberry" \
      org.opencontainers.image.description="Amiberry Amiga emulator with KasmVNC web access" \
      org.opencontainers.image.version="${AMIBERRY_VERSION}"

ENV VNC_USER=amiberry \
    APP_LOG=/config/amiberry.log \
    SDL_AUDIODRIVER=pulseaudio

# amiberry's release build renders through its own OpenGL path (llvmpipe here).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libegl1 libgles2 libglx-mesa0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) arch=amd64 ;; \
        arm64) arch=arm64 ;; \
    esac; \
    curl -fsSL -o /tmp/amiberry.zip \
        "https://github.com/BlitterStudio/amiberry/releases/download/v${AMIBERRY_VERSION}/amiberry-v${AMIBERRY_VERSION}-debian-trixie-${arch}.zip"; \
    cd /tmp && unzip amiberry.zip; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/amiberry_*.deb; \
    rm -f /tmp/amiberry.zip /tmp/amiberry_*.deb; \
    rm -rf /var/lib/apt/lists/*

# Seed configs copied into the image; app-init.sh installs them into the
# /config volume on startup (default.uae only if absent; vnc-default.uae is
# always refreshed as a pristine fallback).
COPY apps/amiberry/config/ /opt/app-seed/
COPY apps/amiberry/app-init.sh /usr/local/lib/app-init.sh
COPY apps/amiberry/start-app /usr/local/bin/start-app
RUN chmod +x /usr/local/bin/start-app
