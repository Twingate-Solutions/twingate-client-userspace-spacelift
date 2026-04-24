FROM ubuntu:22.04

# Install everything we need:
#   - proxytunnel: bridges TCP through HTTP CONNECT
#   - postgresql-client: psql for testing
#   - curl + gnupg: to install the Twingate client
#   - procps: provides 'ps' (required by Spacelift)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      gnupg \
      procps \
      proxytunnel \
      postgresql-client \
    && curl -s https://binaries.twingate.com/client/linux/install.sh | bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Pre-create directories with the right permissions so the spacelift user can write at runtime
RUN mkdir -p /etc/twingate && chown 1983:1983 /etc/twingate
RUN mkdir -p /run/user/1983 && chown 1983:1983 /run/user/1983

# Spacelift runs everything as user 'spacelift' (UID 1983)
# This also proves we don't need root for userspace mode
RUN adduser --disabled-password --uid 1983 spacelift

USER spacelift
