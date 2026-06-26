FROM node:lts-trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget git openssh-client build-essential python3 python3-pip zstd \
    g++ make ca-certificates rclone nginx jq curl procps \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir huggingface_hub requests PyGithub --break-system-packages

RUN npm install -g openclaw@latest hexo-cli

RUN LATEST_TAG=$(curl -s https://api.github.com/repos/OpenListTeam/OpenList/releases/latest | jq -r '.tag_name') && \
    echo ">>> ${LATEST_TAG} <<<" && \
    wget -O /tmp/openlist.tar.gz https://github.com/OpenListTeam/OpenList/releases/download/${LATEST_TAG}/openlist-linux-amd64.tar.gz && \
    tar -xzf /tmp/openlist.tar.gz -C /usr/local/bin/ openlist && \
    chmod +x /usr/local/bin/openlist && \
    rm -f /tmp/openlist.tar.gz

WORKDIR /app
COPY sync.py .
COPY start-openclaw.sh .
COPY actions.py .
RUN chmod +x start-openclaw.sh
RUN hexo init hexo-blog && cd hexo-blog && npm i

RUN mkdir -p /root/.openclaw/skills /root/.openclaw/agents/main/sessions \
 && chmod -R 755 /root/.openclaw \
 && mkdir -p /app/data

ENV PORT=7860 HOME=/root

EXPOSE 7860

CMD ["./start-openclaw.sh"]