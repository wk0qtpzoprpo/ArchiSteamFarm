#!/bin/sh
# =====================================================================
# ArchiSteamFarm Docker 自定义入口
# 功能：把 compose 环境变量 ASF_IPC_PASSWORD 注入 /app/config/ASF.json
#       （设置 IPCPassword=明文，IPCPasswordFormat=0，IPC=true），
#       然后 exec 官方启动脚本 ArchiSteamFarm.sh（参数透传）。
# 说明：
#   - 仅当 ASF_IPC_PASSWORD 非空时才注入；未设置则保持 config 原样。
#   - 若 ASF.json 已存在，用 jq 就地更新对应字段（环境变量为准）。
#   - 若 ASF.json 不存在，生成只含必要字段的最小配置，由 ASF 启动时补齐。
# =====================================================================
set -eu

ASF_PATH="${ASF_PATH:-/app}"
CONFIG_DIR="${ASF_PATH}/config"
ASF_JSON="${CONFIG_DIR}/ASF.json"

mkdir -p "$CONFIG_DIR"

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
