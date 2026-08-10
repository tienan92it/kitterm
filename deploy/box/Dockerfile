# A container that runs coding agents and serves their terminals to your phone.
#
# Build from the repository root:
#   docker build -f deploy/box/Dockerfile -t kitterm-box .
#
# Everything is compiled in: no host-built binaries to copy in, and no Swift
# runtime in the final image — both executables are linked with a static
# stdlib, because SwiftPM links even the C spawn helper against libswiftCore.
FROM swift:6.1 AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
# SwiftPM validates every declared target's path, test targets included.
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --static-swift-stdlib --product kitterm \
 && swift build -c release --static-swift-stdlib --product kitterm-spawn-helper \
 && mkdir -p /out \
 && cp "$(find .build -name kitterm -type f -perm -u+x | head -1)" /out/ \
 && cp "$(find .build -name kitterm-spawn-helper -type f -perm -u+x | head -1)" /out/

FROM node:22-slim AS web
WORKDIR /web
# Pinned: the lockfile is v9, which pnpm 8 rejects and pnpm 11 reads with
# different settings handling. --ignore-scripts skips esbuild's postinstall,
# which pnpm 10 blocks by default; vite resolves the binary from the platform
# package regardless.
RUN npm install -g pnpm@10
COPY Web/terminal/package.json Web/terminal/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --ignore-scripts
COPY Web/terminal ./
RUN pnpm build

# The same base agentbox uses, so a box built this way and an agentbox box
# behave alike.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl iptables \
 && curl -fsSL https://tailscale.com/install.sh | sh \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y -qq --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/kitterm /usr/local/bin/kitterm
COPY --from=build /out/kitterm-spawn-helper /usr/local/bin/kitterm-spawn-helper
COPY --from=web /web/dist /opt/kitterm-web
COPY deploy/box/entrypoint.sh /usr/local/bin/box-entrypoint
RUN chmod 755 /usr/local/bin/kitterm /usr/local/bin/kitterm-spawn-helper \
              /usr/local/bin/box-entrypoint \
 && su vscode -c 'kitterm integrate bash >> /home/vscode/.bashrc' \
 && printf '\n# Open panes in the mounted workspace, not $HOME.\ncd /workspace 2>/dev/null || true\n' \
      >> /home/vscode/.bashrc

ENV KITTERM_WEB_ROOT=/opt/kitterm-web SHELL=/bin/bash
WORKDIR /workspace
EXPOSE 3418
ENTRYPOINT ["/usr/local/bin/box-entrypoint"]
