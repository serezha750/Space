#!/bin/sh
set -e

echo "====================== 写入 rclone 配置 ========================"

mkdir -p /home/node/.config/rclone
chown -R node:node /home/node/.config/rclone

CONFIG_PATH="/home/node/.config/rclone/rclone.conf"

if [ -n "$RCLONE_CONF" ]; then
    printf '%s\n' "$RCLONE_CONF" > "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    chown node:node "$CONFIG_PATH"
    echo "→ 已成功写入 $CONFIG_PATH"
else
    echo "警告：环境变量 RCLONE_CONF 为空，将创建空的配置文件" >&2
    touch "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    chown node:node "$CONFIG_PATH"
    echo "→ 已创建空文件 $CONFIG_PATH"
fi

echo "================================================================"
echo ""

exec n8n "$@"
