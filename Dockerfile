FROM ubuntu:22.04

# Install:
#   - proxytunnel: bridges TCP through HTTP CONNECT proxy
#   - postgresql-client: psql for DB connectivity testing
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

# Pre-create the Twingate IPC socket directory for the spacelift user.
# Note: /etc/twingate is no longer needed — twingated reads the service key
# from the TWINGATE_SERVICE_KEY environment variable natively.
RUN mkdir -p /run/user/1983 && chown 1983:1983 /run/user/1983

# Bake the init script into the image
COPY init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

# Spacelift requires user 'spacelift' with UID 1983.
# Do NOT use --no-create-home — Spacelift needs /home/spacelift/ for .terraformrc
RUN adduser --disabled-password --uid 1983 spacelift

USER spacelift
