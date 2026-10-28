# Debian 11 glibc 2.31 preserves the Ubuntu 20.04 release baseline.
FROM python@sha256:df0bd610af061603b29d63eb82027b64d5a3f15506e39270422b10b2a55079fc
ARG DEBIAN_FRONTEND=noninteractive
RUN printf '%s\n' \
    'deb https://deb.debian.org/debian bullseye main' \
    > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends libwayland-bin=1.18.0-2~exp1.1 \
    && dpkg-query -W > /usr/share/bloodshot-engine-packages.txt \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/engine-requirements.txt
RUN python3 -m pip install --no-cache-dir --require-hashes -r /tmp/engine-requirements.txt
WORKDIR /source
