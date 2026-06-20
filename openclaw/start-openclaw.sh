#!/bin/bash
set -e

COMMON_CONTEXT=1000000
COMMON_MAX_TOKENS=1000000

mkdir -p /data/openclaw /data/appdata /app/data
ln -sfn /data/openclaw /root/.openclaw
ln -sfn /data/appdata /app/data

mkdir -p /root/.openclaw/agents/main/agent \
         /root/.openclaw/credentials \
         /root/.openclaw/workspace/memory \
         /app/data \

echo "执行数据恢复..."
python3 /app/sync.py restore || echo "恢复失败，继续..."

if [ -n "${RCLONE_CONF:-}" ]; then
    mkdir -p ~/.config/rclone
    printf '%s\n' "$RCLONE_CONF" > ~/.config/rclone/rclone.conf
    chmod 600 ~/.config/rclone/rclone.conf
    echo "✓ rclone 配置已写入"
fi


echo "清理旧配置"
CONFIG_PATH="/root/.openclaw/openclaw.json"

echo "→ 设置 OPENCLAW_ROOT..."
export OPENCLAW_ROOT=$(npm root -g)/openclaw
echo "   OPENCLAW_ROOT 已设置为: $OPENCLAW_ROOT"

# ---------- 收集 API Keys ----------
declare -a google_keys=()
if [ -n "$GOOGLE_AI_API_KEY" ]; then google_keys+=("$GOOGLE_AI_API_KEY"); fi
for var in $(compgen -v | grep -E '^GOOGLE_AI_API_KEY[0-9]+$' | sort -V); do
    value=${!var}; [ -n "$value" ] && { duplicate=0; for existing in "${google_keys[@]}"; do [ "$existing" = "$value" ] && duplicate=1; done; [ $duplicate -eq 0 ] && google_keys+=("$value"); }
done
google_count=${#google_keys[@]}

declare -a ollama_keys=()
if [ -n "$OLLAMA_API_KEY" ]; then ollama_keys+=("$OLLAMA_API_KEY"); fi
for var in $(compgen -v | grep -E '^OLLAMA_API_KEY[0-9]+$' | sort -V); do
    value=${!var}; [ -n "$value" ] && { duplicate=0; for existing in "${ollama_keys[@]}"; do [ "$existing" = "$value" ] && duplicate=1; done; [ $duplicate -eq 0 ] && ollama_keys+=("$value"); }
done
ollama_count=${#ollama_keys[@]}

declare -a workersai_keys=()
if [ -n "$WORKERS_AI_API_KEY" ]; then workersai_keys+=("$WORKERS_AI_API_KEY"); fi
for var in $(compgen -v | grep -E '^WORKERS_AI_API_KEY[0-9]+$' | sort -V); do
    value=${!var}; [ -n "$value" ] && { duplicate=0; for existing in "${workersai_keys[@]}"; do [ "$existing" = "$value" ] && duplicate=1; done; [ $duplicate -eq 0 ] && workersai_keys+=("$value"); }
done
workersai_count=${#workersai_keys[@]}

echo "Google Keys: ${google_count}, Ollama Keys: ${ollama_count}, Workers AI Keys: ${workersai_count}"

# ---------- 构建 providers JSON ----------
providers='{}'

# ----- Google: 动态获取模型（仅保留三个指定模型）-----
GOOGLE_MODELS_JSON="[]"
if [ $google_count -gt 0 ] && command -v curl &> /dev/null && command -v jq &> /dev/null; then
    echo "→ 正在从 Google API 动态获取可用模型，并过滤仅保留：gemma-4-26b-a4b-it, gemma-4-31b-it, gemini-3.1-flash-lite-preview"
    FIRST_GOOGLE_KEY="${google_keys[0]}"
    API_URL="https://generativelanguage.googleapis.com/v1beta/models?key=${FIRST_GOOGLE_KEY}&pageSize=1000"
    
    GOOGLE_MODELS_JSON=$(curl -s "$API_URL" | jq -c --argjson ctx "$COMMON_CONTEXT" --argjson mt "$COMMON_MAX_TOKENS" '
        .models // [] | 
        map(select(.supportedGenerationMethods | index("generateContent"))) | 
        map(select(
            (.name | sub("^models/"; "")) as $modelId |
            $modelId == "gemma-4-26b-a4b-it" or
            $modelId == "gemma-4-31b-it" or
            $modelId == "gemini-3.1-flash-lite-preview"
        )) |
        map({
            id: (.name | sub("^models/"; "")),
            name: (.displayName // .name),
            reasoning: false,
            input: (if (.inputTokenLimit // 0) > 0 then ["text"] else ["text"] end),
            cost: {input: 0, output: 0},
            contextWindow: (.inputTokenLimit // $ctx),
            maxTokens: (.outputTokenLimit // $mt)
        })
    ')
    
    if [ "$GOOGLE_MODELS_JSON" = "[]" ] || [ -z "$GOOGLE_MODELS_JSON" ]; then
        echo "⚠️ 动态获取未能匹配到指定模型，使用硬编码后备列表（仅三个模型）"
        GOOGLE_MODELS_JSON=$(jq -n \
            --argjson ctx "$COMMON_CONTEXT" \
            --argjson mt "$COMMON_MAX_TOKENS" \
            '[
                {"id":"gemma-4-26b-a4b-it","name":"Gemma 4 26B A4B IT","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
                {"id":"gemma-4-31b-it","name":"Gemma 4 31B IT","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
                {"id":"gemini-3.1-flash-lite-preview","name":"Gemini 3.1 Flash Lite Preview","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt}
            ]')
    else
        MODEL_COUNT=$(echo "$GOOGLE_MODELS_JSON" | jq length)
        echo "✓ 成功获取并过滤出 ${MODEL_COUNT} 个 Google 模型"
    fi
else
    if [ $google_count -eq 0 ]; then
        echo "⚠️ 未配置 Google API Key，跳过 Google provider"
    else
        echo "⚠️ 缺少 curl 或 jq 命令，使用硬编码后备列表（仅三个模型）"
        GOOGLE_MODELS_JSON=$(jq -n \
            --argjson ctx "$COMMON_CONTEXT" \
            --argjson mt "$COMMON_MAX_TOKENS" \
            '[
                {"id":"gemma-4-26b-a4b-it","name":"Gemma 4 26B A4B IT","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
                {"id":"gemma-4-31b-it","name":"Gemma 4 31B IT","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
                {"id":"gemini-3.1-flash-lite-preview","name":"Gemini 3.1 Flash Lite Preview","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt}
            ]')
    fi
fi

if [ "$GOOGLE_MODELS_JSON" != "[]" ]; then
    providers=$(jq --argjson models "$GOOGLE_MODELS_JSON" \
        '. + {google: {"baseUrl":"https://generativelanguage.googleapis.com/v1beta","api":"google-generative-ai","models":$models}}' <<<"$providers")
fi

# ----- Ollama -----
if [ $ollama_count -gt 0 ]; then
    ollama_models_json=$(jq -n \
        --argjson ctx "$COMMON_CONTEXT" \
        --argjson mt "$COMMON_MAX_TOKENS" \
        '[
            {"id":"gemma4:31b-cloud","name":"Gemma4 31B Cloud","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"gemini-3-flash-preview:cloud","name":"Gemini 3 Flash Preview Cloud","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"nemotron-3-super:cloud","name":"Nemotron 3 Super Cloud","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"qwen3-vl:235b-cloud","name":"Qwen3 VL 235B Cloud","reasoning":false,"input":["text","image"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt}
        ]')
    providers=$(jq --argjson models "$ollama_models_json" '. + {ollama: {"baseUrl":"https://ollama.com","api":"ollama","models":$models}}' <<<"$providers")
fi

# ----- Cloudflare Workers AI -----
if [ $workersai_count -gt 0 ]; then
    workersai_models_json=$(jq -n \
        --argjson ctx "$COMMON_CONTEXT" \
        --argjson mt "$COMMON_MAX_TOKENS" \
        '[
            {"id":"@cf/nvidia/nemotron-3-120b-a12b","name":"CF-nemotron-3-120b-a12b","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"@cf/openai/gpt-oss-120b","name":"CF-gpt-oss-120b","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"@cf/qwen/qwen3-30b-a3b-fp8","name":"CF-qwen3-30b-a3b-fp8","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"@cf/cf/deepseek-ai/deepseek-r1-distill-qwen-32b","name":"CF-deepseek-r1","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt},
            {"id":"@cf/moonshotai/kimi-k2.6","name":"CF-Kimi K2.6","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":$ctx,"maxTokens":$mt}
        ]')
    first_workersai_key="${workersai_keys[0]}"
    workersai_account_id="${first_workersai_key%%:*}"
    providers=$(jq --argjson models "$workersai_models_json" --arg account "$workersai_account_id" \
        '. + {"cloudflare-workers-ai": {"baseUrl": ("https://api.cloudflare.com/client/v4/accounts/" + $account + "/ai/v1"), "api":"openai-completions", "models": $models}}' <<<"$providers")
    echo "✓ Cloudflare Workers AI provider 已加入（${workersai_count} 个 Key，Account: ${workersai_account_id}）"
fi

# ---------- 生成 auth-profiles.json ----------
AUTH_PROFILES_PATH="/root/.openclaw/agents/main/agent/auth-profiles.json"
echo "→ 生成 auth-profiles.json..."
auth_profiles='{"profiles":{}}'

for ((i=0; i<google_count; i++)); do
    key="${google_keys[$i]}"; profile_id="google:key$((i+1))"
    auth_profiles=$(jq --arg id "$profile_id" --arg key "$key" '.profiles[$id] = {provider:"google", mode:"api_key", key:$key}' <<<"$auth_profiles")
done
for ((i=0; i<ollama_count; i++)); do
    key="${ollama_keys[$i]}"; profile_id="ollama:key$((i+1))"
    auth_profiles=$(jq --arg id "$profile_id" --arg key "$key" '.profiles[$id] = {provider:"ollama", mode:"api_key", key:$key}' <<<"$auth_profiles")
done
for ((i=0; i<workersai_count; i++)); do
    key="${workersai_keys[$i]}"; profile_id="cloudflare-workers-ai:key$((i+1))"
    api_key="${key#*:}"
    auth_profiles=$(jq --arg id "$profile_id" --arg key "$api_key" '.profiles[$id] = {provider:"cloudflare-workers-ai", mode:"api_key", key:$key}' <<<"$auth_profiles")
done

echo "$auth_profiles" > "$AUTH_PROFILES_PATH"
chmod 600 "$AUTH_PROFILES_PATH"
echo "✓ auth-profiles.json 已生成"

# ---------- 构建 fallbacks 列表 ----------
google_models_list=()
if [ $google_count -gt 0 ]; then
    while IFS= read -r model_id; do
        google_models_list+=("google/$model_id")
    done < <(echo "$GOOGLE_MODELS_JSON" | jq -r '.[].id')
fi

ollama_models_list=()
if [ $ollama_count -gt 0 ]; then
    ollama_models_list=(
        "ollama/gemini-3-flash-preview:cloud"
        "ollama/gemma4:31b-cloud"
        "ollama/nemotron-3-super:cloud"
        "ollama/qwen3-vl:235b-cloud"
    )
fi

workersai_models_list=()
if [ $workersai_count -gt 0 ]; then
    workersai_models_list=(
        "cloudflare-workers-ai/@cf/nvidia/nemotron-3-120b-a12b"
        "cloudflare-workers-ai/@cf/openai/gpt-oss-120b"
        "cloudflare-workers-ai/@cf/qwen/qwen3-30b-a3b-fp8"
        "cloudflare-workers-ai/@cf/cf/deepseek-ai/deepseek-r1-distill-qwen-32b"
        "cloudflare-workers-ai/@cf/moonshotai/kimi-k2.6"
    )
fi

DEFAULT_PRIMARY="ollama/gemma4:31b-cloud"
if [ ${#ollama_models_list[@]} -eq 0 ] && [ ${#google_models_list[@]} -gt 0 ]; then
    DEFAULT_PRIMARY="${google_models_list[0]}"
fi

# 从 fallbacks 中移除默认主模型
for list_name in google_models_list ollama_models_list workersai_models_list; do
    eval "
        filtered=()
        for item in \"\${${list_name}[@]}\"; do
            if [[ \"\$item\" != \"$DEFAULT_PRIMARY\" ]]; then
                filtered+=(\"\$item\")
            fi
        done
        $list_name=(\"\${filtered[@]}\")
    "
done

providers_lists=()
[ ${#google_models_list[@]} -gt 0 ] && providers_lists+=("google_models_list")
[ ${#ollama_models_list[@]} -gt 0 ] && providers_lists+=("ollama_models_list")
[ ${#workersai_models_list[@]} -gt 0 ] && providers_lists+=("workersai_models_list")

declare -a indexes
for ((i=0; i<${#providers_lists[@]}; i++)); do indexes[$i]=0; done

total_models=0
for list_name in "${providers_lists[@]}"; do
    len=$(eval echo \${#${list_name}[@]})
    total_models=$((total_models + len))
done

round_robin_fallbacks=()
while [ ${#round_robin_fallbacks[@]} -lt $total_models ]; do
    for idx in "${!providers_lists[@]}"; do
        list_name="${providers_lists[$idx]}"
        current_index=${indexes[$idx]}
        list_len=$(eval echo \${#${list_name}[@]})
        if [ $current_index -lt $list_len ]; then
            model=$(eval echo \${${list_name}[$current_index]})
            round_robin_fallbacks+=("$model")
            indexes[$idx]=$((current_index + 1))
        fi
    done
done

fallbacks=$(printf '%s\n' "${round_robin_fallbacks[@]}" | jq -R . | jq -s .)
echo "最终 fallbacks 顺序（共 $(echo "$fallbacks" | jq length) 个）:"

# ---------- 构建 auth_order ----------
auth_order='{}'
if [ $google_count -gt 0 ]; then
    google_order='[]'
    for ((i=0; i<google_count; i++)); do
        profile="google:key$((i+1))"
        google_order=$(jq --arg p "$profile" '. + [$p]' <<<"$google_order")
    done
    auth_order=$(jq --argjson o "$google_order" '. + {"google": $o}' <<<"$auth_order")
fi
if [ $ollama_count -gt 0 ]; then
    ollama_order='[]'
    for ((i=0; i<ollama_count; i++)); do
        profile="ollama:key$((i+1))"
        ollama_order=$(jq --arg p "$profile" '. + [$p]' <<<"$ollama_order")
    done
    auth_order=$(jq --argjson o "$ollama_order" '. + {"ollama": $o}' <<<"$auth_order")
fi
if [ $workersai_count -gt 0 ]; then
    workersai_order='[]'
    for ((i=0; i<workersai_count; i++)); do
        profile="cloudflare-workers-ai:key$((i+1))"
        workersai_order=$(jq --arg p "$profile" '. + [$p]' <<<"$workersai_order")
    done
    auth_order=$(jq --argjson o "$workersai_order" '. + {"cloudflare-workers-ai": $o}' <<<"$auth_order")
fi

# ---------- 生成主配置 ----------
base_config=$(jq -n \
    --arg primary "$DEFAULT_PRIMARY" \
    --argjson auth_order "$auth_order" \
    '{
        "models": { "mode": "merge", "providers": {} },
        "auth": { "order": $auth_order },
        "agents": {
            "defaults": {
                "heartbeat": { "every": "0m" },
                "model": { "primary": $primary, "fallbacks": [] }
            }
        },
        "tools": {
            "exec": {
                "host": "gateway",
                "security": "full",
                "ask": "off",
                "safeBins": ["python3", "ls", "cat", "echo", "jq", "openclaw", "/app/sync.py", "chmod", "mkdir", "cp", "mv", "npm", "pip", "pnpm"]
            },
            "elevated": { "enabled": true, "allowFrom": { "agent": ["main"], "session": ["*"] } }
        },
        "approvals": { "exec": { "enabled": true, "mode": "session", "agentFilter": ["main"] } },
        "gateway": {
            "mode": "local",
            "bind": "lan",
            "port": 7861,
            "trustedProxies": ["0.0.0.0/0"],
            "auth": { "mode": "token", "token": "${OPENCLAW_GATEWAY_PASSWORD}" },
            "controlUi": {
                "enabled": true,
                "allowInsecureAuth": true,
                "dangerouslyDisableDeviceAuth": true,
                "dangerouslyAllowHostHeaderOriginFallback": true
            }
        }
    }')

final_config=$(jq --argjson providers "$providers" \
                  --argjson fallbacks "$fallbacks" \
    '.models.providers = $providers | .agents.defaults.model.fallbacks = $fallbacks' <<<"$base_config")
final_config=$(jq 'del(.agents.defaults.models?)' <<<"$final_config")
final_config=$(jq '. + {session: {reset: {mode: "idle", idleMinutes: 525600}}}' <<<"$final_config")

echo "$final_config" > "$CONFIG_PATH"
echo "✓ openclaw.json 已生成"

openclaw doctor --fix || true

EXEC_APPROVALS_PATH="/root/.openclaw/exec-approvals.json"
cat > "$EXEC_APPROVALS_PATH" <<'EOT'
{
  "version": 1,
  "defaults": { "security": "full", "ask": "off", "askFallback": "full", "autoAllowSkills": true },
  "agents": { "main": { "security": "full", "ask": "off" } }
}
EOT
openclaw approvals set --gateway --file "$EXEC_APPROVALS_PATH" || true

chmod -R 750 /root/.openclaw 2>/dev/null || true

(
while true; do
    now=$(date +%s)
    sleep_time=$(( 7200 - (now % 7200) ))
    echo "[Backup] Current: $(date), Next run in $sleep_time s"
    sleep $sleep_time
    python3 /app/sync.py backup || echo "备份失败..."
done
) &

(
while true; do
    now=$(date +%s)
    this_hour_5min=$(date -d "$(date +%Y-%m-%d\ %H):10:00" +%s)
    if [ "$now" -ge "$this_hour_5min" ]; then
        target_time=$(( this_hour_5min + 3600 ))
    else
        target_time=$this_hour_5min
    fi
    sleep_time=$(( target_time - now ))
    echo "[GitHub] Current: $(date), Next run in $sleep_time s"
    sleep $sleep_time
    python3 /app/GitHubActions.py
done
) &

openlist server &
sleep 5
if [ -n "$NEW_PASSWORD" ]; then
    openlist admin set --data /app/data "$NEW_PASSWORD" || true
fi

cat > /etc/nginx/nginx.conf <<'EOF'
worker_processes 1;
events {
    worker_connections 1024;
}

http {
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    limit_req_zone $binary_remote_addr zone=anti_crawl:10m rate=100r/m;

    map $http_user_agent $bad_bot {
        default                             0;
        ~*(scrapy|python-requests|Go-http-client|curl|wget)    1;
        ~*(HTTrack|sqlmap|nmap|nikto|dirbuster|havij)         1;
        ~*(MJ12bot|AhrefsBot|SemrushBot|petalbot|DotBot)       1;
        ~*(ia_archiver|archive.org_bot)                       1;
    }

    server {
        listen 7860;
        server_name _;

        if ($bad_bot) {
            return 403;
        }

        location = /robots.txt {
            default_type text/plain;
            return 200 "User-agent: *\nDisallow: /\n";
        }

        limit_req zone=anti_crawl burst=20 nodelay;
        limit_req_status 429;

        location /openclaw {
            proxy_pass http://127.0.0.1:7861/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /openclaw/ {
            proxy_pass http://127.0.0.1:7861/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header X-Forwarded-Host $host;
        }

        location /assets/ {
            proxy_pass http://127.0.0.1:5244/assets/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Accept-Encoding "";
            sub_filter_types application/javascript text/css;
            sub_filter_once off;
            sub_filter '"/assets/' '"/openlist/assets/';
            sub_filter "'/assets/" "'/openlist/assets/";
        }

        location /openlist/static/ {
            proxy_pass http://127.0.0.1:5244/static/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /openlist/assets/ {
            proxy_pass http://127.0.0.1:5244/assets/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Accept-Encoding "";

            sub_filter_types application/javascript text/css;
            sub_filter_once off;
            sub_filter '"/assets/' '"/openlist/assets/';
            sub_filter "'/assets/" "'/openlist/assets/";
            sub_filter '"/api/' '"/openlist/api/';
        }

        location /openlist/api/ {
            proxy_pass http://127.0.0.1:5244/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location ~ ^/openlist/(manifest\.json|favicon\.svg|logo/) {
            proxy_pass http://127.0.0.1:5244$request_uri;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /openlist/ {
            proxy_pass http://127.0.0.1:5244/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            client_max_body_size 20000m;

            sub_filter_types *;
            sub_filter_once off;
            sub_filter 'api: undefined,' 'api: "/openlist/",';
            sub_filter "base_path: '/'," "base_path: '/openlist',";
            sub_filter 'src="/assets/' 'src="/openlist/assets/';
            sub_filter 'href="/assets/' 'href="/openlist/assets/';
            sub_filter 'data-src="/assets/' 'data-src="/openlist/assets/';
            sub_filter 'src="/static/' 'src="/openlist/static/';
            sub_filter 'href="/static/' 'href="/openlist/static/';
            sub_filter 'href="/manifest.json' 'href="/openlist/manifest.json';
            sub_filter 'href="/favicon' 'href="/openlist/favicon';
            sub_filter '"/assets/' '"/openlist/assets/';
            proxy_set_header Accept-Encoding "";
        }

        location = /ql {
            return 301 /ql/;
        }

        location ^~ /ql/ {
            proxy_pass http://127.0.0.1:5700;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Prefix /ql;
            proxy_set_header X-Script-Name /ql;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header Accept-Encoding "";
        }

        location ^~ /api/ {
            proxy_pass http://127.0.0.1:5700;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Prefix /ql;
            proxy_set_header X-Script-Name /ql;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header Accept-Encoding "";
        }

        location ^~ /src__ {
            proxy_pass http://127.0.0.1:5700;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location ^~ /umi. {
            proxy_pass http://127.0.0.1:5700;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location = / {
            return 302 /openlist/;
        }
    }
}
EOF

nginx -t && nginx || true

echo "启动 OpenClaw Gateway（主模型：${DEFAULT_PRIMARY}）"
export NODE_OPTIONS="--dns-result-order=ipv4first"
exec openclaw gateway run --port 7861