# syntax=docker/dockerfile:1
# =====================================================================
# ArchiSteamFarm 自建 Docker 镜像（基于官方 Dockerfile 扩展）
# 来源：https://github.com/JustArchiNET/ArchiSteamFarm/blob/main/Dockerfile
# 本版本相对官方新增两点：
#   1) 运行时安装 jq，用于把 compose 传入的 ASF_IPC_PASSWORD 环境变量
#      注入 /app/config/ASF.json（IPC 密码，IPCPasswordFormat=0 明文）
#   2) 自定义入口 docker-entrypoint.sh：先注入密码，再 exec 启动 ASF
# 注意：构建需要 BuildKit（Docker 23+ / compose v2 默认满足）
# =====================================================================

ARG IMAGESUFFIX

FROM --platform=$BUILDPLATFORM node:lts${IMAGESUFFIX} AS build-node
WORKDIR /app/ASF-ui
COPY --link ASF-ui .
COPY --link .git/modules/ASF-ui /app/.git/modules/ASF-ui

RUN <<EOF
    set -eu

    echo "node: $(node --version)"
    echo "npm: $(npm --version)"

    npm ci --no-progress
    npm run deploy --no-progress
EOF

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0${IMAGESUFFIX} AS build-dotnet
ARG CONFIGURATION=Release
ARG TARGETARCH
ARG TARGETOS
ENV DOTNET_CLI_TELEMETRY_OPTOUT=true
ENV DOTNET_NOLOGO=true
ENV PLUGINS_BUNDLED="ArchiSteamFarm.OfficialPlugins.ItemsMatcher ArchiSteamFarm.OfficialPlugins.MobileAuthenticator ArchiSteamFarm.OfficialPlugins.SteamTokenDumper"
WORKDIR /app
COPY --from=build-node --link /app/ASF-ui/dist ASF-ui/dist
COPY --link ArchiSteamFarm ArchiSteamFarm
COPY --link ArchiSteamFarm.OfficialPlugins.ItemsMatcher ArchiSteamFarm.OfficialPlugins.ItemsMatcher
COPY --link ArchiSteamFarm.OfficialPlugins.MobileAuthenticator ArchiSteamFarm.OfficialPlugins.MobileAuthenticator
COPY --link ArchiSteamFarm.OfficialPlugins.SteamTokenDumper ArchiSteamFarm.OfficialPlugins.SteamTokenDumper
COPY --link resources resources
COPY --link .editorconfig .editorconfig
COPY --link Directory.Build.props Directory.Build.props
COPY --link Directory.Packages.props Directory.Packages.props
COPY --link LICENSE.txt LICENSE.txt

# ASF_PRIVATE_SNK / STEAM_TOKEN_DUMPER_TOKEN 为可选 secret，本地构建可省略（官方 CI 亦如此）
RUN --mount=type=secret,id=ASF_PRIVATE_SNK --mount=type=secret,id=STEAM_TOKEN_DUMPER_TOKEN <<EOF
    set -eu

    dotnet --info

    case "$TARGETOS" in
        "linux") ;;
        *) echo "ERROR: Unsupported OS: ${TARGETOS}"; exit 1 ;;
    esac

    case "$TARGETARCH" in
        "amd64") asf_variant="${TARGETOS}-x64" ;;
        "arm") asf_variant="${TARGETOS}-${TARGETARCH}" ;;
        "arm64") asf_variant="${TARGETOS}-${TARGETARCH}" ;;
        *) echo "ERROR: Unsupported CPU architecture: ${TARGETARCH}"; exit 1 ;;
    esac

    if [ -f "/run/secrets/ASF_PRIVATE_SNK" ]; then
        base64 -d "/run/secrets/ASF_PRIVATE_SNK" > "resources/ArchiSteamFarm.snk"
    else
        echo "WARN: No ASF_PRIVATE_SNK provided!"
    fi

    dotnet publish ArchiSteamFarm -c "$CONFIGURATION" -o "out" -p:ASFVariant=docker -p:ContinuousIntegrationBuild=true -p:UseAppHost=false -r "$asf_variant" --nologo --no-self-contained

    if [ -f "/run/secrets/STEAM_TOKEN_DUMPER_TOKEN" ]; then
        STEAM_TOKEN_DUMPER_TOKEN="$(cat "/run/secrets/STEAM_TOKEN_DUMPER_TOKEN")"

        if [ -n "$STEAM_TOKEN_DUMPER_TOKEN" ] && [ -f "ArchiSteamFarm.OfficialPlugins.SteamTokenDumper/SharedInfo.cs" ]; then
            sed -i "s/STEAM_TOKEN_DUMPER_TOKEN/${STEAM_TOKEN_DUMPER_TOKEN}/g" "ArchiSteamFarm.OfficialPlugins.SteamTokenDumper/SharedInfo.cs"
        else
            echo "WARN: STEAM_TOKEN_DUMPER_TOKEN not applied!"
        fi
    else
        echo "WARN: No STEAM_TOKEN_DUMPER_TOKEN provided!"
    fi

    for plugin in $PLUGINS_BUNDLED; do
        dotnet publish "$plugin" -c "$CONFIGURATION" -o "out/plugins/$plugin" -p:ASFVariant=docker -p:ContinuousIntegrationBuild=true -p:UseAppHost=false -r "$asf_variant" --nologo
    done
EOF

FROM mcr.microsoft.com/dotnet/aspnet:10.0${IMAGESUFFIX} AS runtime
ENV ASF_PATH=/app
ENV ASF_UID=1000
ENV ASPNETCORE_URLS=
ENV DOTNET_CLI_TELEMETRY_OPTOUT=true
ENV DOTNET_EnableDiagnostics=0
ENV DOTNET_NOLOGO=true

LABEL maintainer="Fork build <asf-docker-workflow>" \
    org.opencontainers.image.source="https://github.com/wk0qtpzoprpo/ArchiSteamFarm" \
    org.opencontainers.image.licenses="Apache-2.0" \
    org.opencontainers.image.title="ArchiSteamFarm (custom)" \
    org.opencontainers.image.description="C# application with primary purpose of idling Steam cards from multiple accounts simultaneously"

EXPOSE 1242
COPY --from=build-dotnet --link /app/out /asf
# 把默认 IPC.config 打进镜像（Render 等无卷环境也能在 0.0.0.0:1242 监听；
# 本地 compose 用 bind 卷挂载 ./config 时会覆盖它，工作流已自带该文件）
COPY --link config/IPC.config /app/config/IPC.config

RUN <<EOF
    set -eu

    apt-get update
    apt-get install -y --no-install-recommends jq
    rm -rf /var/lib/apt/lists/*

    mkdir -p "$ASF_PATH"

    if ! id -u "$ASF_UID" >/dev/null 2>&1; then
        groupadd -r -g "$ASF_UID" "asf"
        useradd -r -d "$ASF_PATH" -g "$ASF_UID" -u "$ASF_UID" "asf"
    fi

    chown -hR "${ASF_UID}:${ASF_UID}" "$ASF_PATH" /asf

    ln -s /asf/ArchiSteamFarm.sh /usr/bin/ArchiSteamFarm
EOF

# 自定义入口：先注入 ASF_IPC_PASSWORD 到 ASF.json，再启动 ASF
COPY --chmod=755 docker-entrypoint.sh /usr/bin/docker-entrypoint.sh

WORKDIR /app
VOLUME ["/app/config", "/app/logs"]
HEALTHCHECK CMD ["pidof", "-q", "dotnet"]
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["--no-restart"]
