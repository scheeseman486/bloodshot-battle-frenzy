# Official Ubuntu 20.04 amd64 manifest; apt inputs use a dated signed snapshot.
FROM ubuntu@sha256:c664f8f86ed5a386b0a340d981b8f81714e21a8b9c73f658c4bea56aa179d54a AS runtime
ARG DEBIAN_FRONTEND=noninteractive
# Bootstrap HTTPS trust through Ubuntu's signed archive before using snapshots.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates
RUN printf '%s\n' \
    'deb [check-valid-until=no] http://snapshot.ubuntu.com/ubuntu/20261020T000000Z focal main universe' \
    'deb [check-valid-until=no] http://snapshot.ubuntu.com/ubuntu/20261020T000000Z focal-updates main universe' \
    'deb [check-valid-until=no] http://snapshot.ubuntu.com/ubuntu/20261020T000000Z focal-security main universe' \
    > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libasound2 libpulse0 \
       libx11-6 libxcursor1 libxext6 libxi6 libxinerama1 libxrandr2 libxrender1 \
       libgl1 libvulkan1 mesa-vulkan-drivers xvfb xauth \
    && rm -rf /var/lib/apt/lists/*
ENV HOME=/tmp/home XDG_CONFIG_HOME=/tmp/config XDG_DATA_HOME=/tmp/share XDG_CACHE_HOME=/tmp/cache

FROM runtime AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential cmake binutils \
    && dpkg-query -W > /usr/share/bloodshot-baseline-packages.txt \
    && rm -rf /var/lib/apt/lists/*
COPY build_native.sh /usr/local/bin/build-bloodshot-native
ENTRYPOINT ["/bin/sh", "/usr/local/bin/build-bloodshot-native"]
