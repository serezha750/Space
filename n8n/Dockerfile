FROM alpine:latest AS builder

RUN apk add --no-cache curl unzip && \
    curl -L https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip && \
    unzip /tmp/rclone.zip -d /tmp && \
    mv /tmp/rclone-*/rclone /usr/local/bin/rclone && \
    chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone*

FROM ghcr.io/deluxebear/n8n:latest

USER root

COPY --from=builder /usr/local/bin/rclone /usr/local/bin/rclone

RUN mkdir -p /data/n8n /home/node/.config/rclone && chown -R node:node /data /home/node

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PORT=7860
ENV N8N_PORT=7860
ENV N8N_USER_FOLDER=/data/n8n
ENV N8N_LISTEN_ADDRESS=0.0.0.0
ENV TZ=Asia/Shanghai
ENV GENERIC_TIMEZONE=Asia/Shanghai
ENV N8N_DEFAULT_LOCALE=zh-CN
ENV N8N_LOG_LEVEL=info
ENV NODES_EXCLUDE=[]
ENV N8N_ENTERPRISE_MOCK=true
ENV NODE_ENV=development
ENV N8N_PROXY_HOPS=1
ENV EXECUTIONS_DATA_PRUNE=true
ENV DB_SQLITE_VACUUM_ON_STARTUP=true
ENV EXECUTIONS_DATA_MAX_AGE=24
ENV EXECUTIONS_DATA_PRUNE_MAX_COUNT=100
ENV N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

EXPOSE 7860

ENTRYPOINT ["/entrypoint.sh"]

USER node
