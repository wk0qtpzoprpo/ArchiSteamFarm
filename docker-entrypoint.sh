#!/bin/sh
# =====================================================================
# ArchiSteamFarm Docker 自定义入口
# 功能：
#   1) 确保 config/IPC.config 存在（Kestrel 监听 0.0.0.0，容器外才可访问）
#   2) 若注入 PORT 环境变量（Render 等 PaaS 自动注入），把监听端口改为 $PORT
#   3) 把 compose 环境变量 ASF_IPC_PASSWORD 注入 /app/config/ASF.json
#      （IPCPassword=明文，IPCPasswordFormat=0，IPC=true）
#   然后 exec 官方启动脚本 ArchiSteamFarm.sh（参数透传）。
# =====================================================================
set -eu

ASF_PATH="${ASF_PATH:-/app}"
CONFIG_DIR="${ASF_PATH}/config"
ASF_JSON="${CONFIG_DIR}/ASF.json"
IPC_CONFIG="${CONFIG_DIR}/IPC.config"

mkdir -p "$CONFIG_DIR"

# 1) 确保 IPC.config 存在：ASF 默认只监听 localhost:1242，容器外部无法访问
if [ ! -f "$IPC_CONFIG" ]; then
	printf '{\n\t"Kestrel": {\n\t\t"Endpoints": {\n\t\t\t"HTTP": {\n\t\t\t\t"Url": "http://*:1242"\n\t\t\t}\n\t\t}\n\t}\n}\n' > "$IPC_CONFIG"
	echo "[docker-entrypoint] 已生成默认 ${IPC_CONFIG}（Kestrel 监听 http://*:1242）"
fi

# 2) Render / Heroku 等平台注入 PORT 环境变量：让 Kestrel 改监听 $PORT
if [ -n "${PORT:-}" ] && [ "$PORT" != "1242" ]; then
	TMP_IPC="$(mktemp)"
	jq --arg url "http://*:${PORT}" '.Kestrel.Endpoints.HTTP.Url = $url' "$IPC_CONFIG" > "$TMP_IPC"
	chmod 644 "$TMP_IPC"
	mv "$TMP_IPC" "$IPC_CONFIG"
	echo "[docker-entrypoint] 检测到 PORT=${PORT}，Kestrel 监听地址已改为 http://*:${PORT}"
fi

# 3) IPC 密码注入（仅当 ASF_IPC_PASSWORD 非空时执行）
if [ -n "${ASF_IPC_PASSWORD:-}" ]; then
	if command -v jq >/dev/null 2>&1; then
		if [ -f "$ASF_JSON" ]; then
			TMP_JSON="$(mktemp)"
			jq --arg pass "$ASF_IPC_PASSWORD" '.IPC = true | .IPCPassword = $pass | .IPCPasswordFormat = 0' "$ASF_JSON" > "$TMP_JSON"
			chmod 644 "$TMP_JSON"
			mv "$TMP_JSON" "$ASF_JSON"
		else
			printf '{}' | jq --arg pass "$ASF_IPC_PASSWORD" '.IPC = true | .IPCPassword = $pass | .IPCPasswordFormat = 0' > "$ASF_JSON"
		fi

		echo "[docker-entrypoint] ASF_IPC_PASSWORD 已写入 ${ASF_JSON}（IPCPasswordFormat=0 明文，IPC=true）"
	else
		echo "[docker-entrypoint] WARN: 镜像内缺少 jq，无法注入 IPC 密码，请检查镜像构建" >&2
	fi
fi

exec /asf/ArchiSteamFarm.sh "$@"
