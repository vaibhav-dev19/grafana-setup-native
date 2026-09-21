#!/bin/bash
set -euo pipefail

# ============================================================
# Grafana + Prometheus + Node Exporter — native install
# No Docker for the core stack. cAdvisor still needs a running
# Docker daemon to introspect containers, so it runs as its own
# container (Docker is installed only if not already present).
# nvidia_gpu_exporter is installed only if an NVIDIA GPU is found.
# ============================================================

# ---- DEFAULTS (used if you just press Enter at each prompt) -
SMTP_HOST="smtp.gmail.com:465"           # 465 confirmed working; 587 failed auth on this account
DEFAULT_SMTP_USER="your@mail.com"
DEFAULT_SMTP_PASSWORD="nottelling"
DEFAULT_ALERT_EMAILS="admin2@admin.com,admin1@admin.com"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="root@1234"
CPU_THRESHOLD=80
RAM_THRESHOLD=80
DISK_THRESHOLD=80
GPU_THRESHOLD=80

GRAFANA_PORT=3001   # 3000 was already in use by another app on this host
PROMETHEUS_PORT=9091   # 9090 already in use on this host
NODE_EXPORTER_PORT=9100
CADVISOR_PORT=8081       # 8080 already in use on this host
NVIDIA_EXPORTER_PORT=9836   # 9835 collided with a docker-proxy container on one host

# Dashboards to import are looked up in the same folder as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# -------------------------------------------------------------

echo "============================================================"
echo " Grafana Monitoring Setup (native services, no Docker)"
echo "============================================================"
echo ""
read -rp "Sender email (SMTP login) [${DEFAULT_SMTP_USER}]: " SMTP_USER
SMTP_USER="${SMTP_USER:-$DEFAULT_SMTP_USER}"

read -rsp "Sender app password [press Enter to use saved default]: " SMTP_PASSWORD
echo ""
SMTP_PASSWORD="${SMTP_PASSWORD:-$DEFAULT_SMTP_PASSWORD}"

SMTP_FROM="$SMTP_USER"

read -rp "Recipient email(s), comma-separated [${DEFAULT_ALERT_EMAILS}]: " ALERT_EMAILS
ALERT_EMAILS="${ALERT_EMAILS:-$DEFAULT_ALERT_EMAILS}"

echo "==> Detecting host IP..."
HOST_IP=$(hostname -I | awk '{print $1}')
echo "    Using host IP: $HOST_IP"

SYSTEM_HOSTNAME=$(hostname)

echo "==> Detecting system UUID..."
SYSTEM_UUID=$(sudo dmidecode -s system-uuid 2>/dev/null | tr -d '\r' || echo "unavailable")
echo "    System UUID: $SYSTEM_UUID"

read -rp "Custom name for this system's alerts (optional) [leave blank to use hostname: $SYSTEM_HOSTNAME]: " CUSTOM_NAME
if [ -n "$CUSTOM_NAME" ]; then
    SMTP_FROM_NAME="${CUSTOM_NAME} - ${HOST_IP}"
else
    SMTP_FROM_NAME="${SYSTEM_HOSTNAME} - ${HOST_IP}"
    CUSTOM_NAME="(none)"
fi

ALERT_FOOTER="IP: ${HOST_IP} | Hostname: ${SYSTEM_HOSTNAME} | Custom Name: ${CUSTOM_NAME} | System UUID: ${SYSTEM_UUID}"

echo ""
echo "Using:"
echo "  Sender:      $SMTP_USER"
echo "  Recipients:  $ALERT_EMAILS"
echo "  Alert name:  $SMTP_FROM_NAME"
echo "  Footer:      $ALERT_FOOTER"
echo ""

# ------------------------------------------------------------------
# Install packages
# ------------------------------------------------------------------
echo "==> Installing prerequisites"
sudo apt-get update
sudo apt-get install -y apt-transport-https software-properties-common wget curl python3 gnupg

echo "==> Adding Grafana apt repo"
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null

echo "==> Installing grafana, prometheus, prometheus-node-exporter"
sudo apt-get update
sudo apt-get install -y grafana prometheus prometheus-node-exporter

# ------------------------------------------------------------------
# cAdvisor — needs Docker to introspect containers, so it runs as
# its own container even though the rest of the stack is native.
# ------------------------------------------------------------------
echo "==> Checking for Docker (required for cAdvisor)"
if ! command -v docker &> /dev/null; then
    echo "    Docker not found — installing docker.io"
    sudo apt-get install -y docker.io
    sudo systemctl enable --now docker
else
    echo "    Docker already present — reusing existing installation"
fi

echo "==> Starting cAdvisor container on port ${CADVISOR_PORT}"
sudo docker rm -f cadvisor > /dev/null 2>&1 || true
sudo docker run -d \
  --name=cadvisor \
  --restart=unless-stopped \
  -p ${CADVISOR_PORT}:8080 \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker/:/var/lib/docker:ro \
  -v /dev/disk/:/dev/disk:ro \
  gcr.io/cadvisor/cadvisor:latest > /dev/null

# ------------------------------------------------------------------
# nvidia_gpu_exporter — only installed if an NVIDIA GPU is present
# AND actually reachable. This ONLY reads GPU state to decide whether
# to install the (unrelated) exporter binary — it never installs,
# upgrades, or touches the NVIDIA driver or CUDA toolkit in any way.
# ------------------------------------------------------------------
echo "==> Detecting NVIDIA GPU"
NVIDIA_SMI_BIN=""
for candidate in nvidia-smi /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi; do
    if command -v "$candidate" &> /dev/null; then
        NVIDIA_SMI_BIN=$(command -v "$candidate")
        break
    fi
done
# command -v only searches this shell's PATH — fall back to an actual
# filesystem search in case nvidia-smi lives somewhere PATH doesn't
# cover (e.g. a non-login/non-interactive script run). Read-only find.
if [ -z "$NVIDIA_SMI_BIN" ]; then
    FOUND=$(sudo find /usr -maxdepth 4 -iname 'nvidia-smi' -type f 2>/dev/null | head -1)
    [ -n "$FOUND" ] && NVIDIA_SMI_BIN="$FOUND"
fi

GPU_EXPORTER_INSTALLED=0
if [ -n "$NVIDIA_SMI_BIN" ] && "$NVIDIA_SMI_BIN" --query-gpu=name --format=csv,noheader &> /dev/null; then
    GPU_NAME=$("$NVIDIA_SMI_BIN" --query-gpu=name --format=csv,noheader | head -1)
    echo "    Found: ${GPU_NAME} (${NVIDIA_SMI_BIN})"
    echo "==> Installing latest nvidia_gpu_exporter (driver/CUDA untouched — only the exporter binary is installed)"
    LATEST_VER=$(curl -sL https://github.com/utkuozdemir/nvidia_gpu_exporter/releases.atom \
      | grep -oE '<title>v[0-9.]+</title>' | head -1 | grep -oE '[0-9.]+')
    TMP_DEB="/tmp/nvidia_gpu_exporter.deb"
    if [ -n "$LATEST_VER" ] && wget -q -O "$TMP_DEB" \
      "https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/latest/download/nvidia-gpu-exporter_${LATEST_VER}_linux_amd64.deb"; then
        sudo dpkg -i "$TMP_DEB"
        echo "==> Setting nvidia_gpu_exporter listen port to ${NVIDIA_EXPORTER_PORT}"
        sudo mkdir -p /etc/systemd/system/nvidia_gpu_exporter.service.d
        sudo tee /etc/systemd/system/nvidia_gpu_exporter.service.d/override.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/nvidia_gpu_exporter --web.listen-address=:${NVIDIA_EXPORTER_PORT}
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable nvidia_gpu_exporter
        sudo systemctl restart nvidia_gpu_exporter   # restart so the port override applies even if already running
        GPU_EXPORTER_INSTALLED=1
    else
        echo "    ⚠️  Could not download nvidia_gpu_exporter — skipping GPU metrics"
    fi
elif [ -n "$NVIDIA_SMI_BIN" ]; then
    echo "    ⚠️  Found nvidia-smi at ${NVIDIA_SMI_BIN} but it couldn't communicate with the GPU — skipping GPU metrics (driver left untouched)"
elif command -v lspci &> /dev/null && lspci | grep -qi nvidia; then
    echo "    ⚠️  NVIDIA hardware detected via lspci, but nvidia-smi isn't available anywhere on this host — skipping GPU metrics (not installing/modifying any driver)"
else
    echo "==> No NVIDIA GPU detected — skipping nvidia_gpu_exporter"
fi

# ------------------------------------------------------------------
# Configure Grafana (admin creds + SMTP) via grafana.ini
# ------------------------------------------------------------------
echo "==> Writing Grafana config (/etc/grafana/grafana.ini)"
# Grafana merges repeated [section] blocks (last key wins), so appending
# an override block is safe even though the file already has these
# sections commented out further up.
sudo tee -a /etc/grafana/grafana.ini > /dev/null << EOF

# --- appended by auto-grafana-installer.sh ---
[server]
http_port = ${GRAFANA_PORT}

[security]
admin_user = ${GRAFANA_ADMIN_USER}
admin_password = ${GRAFANA_ADMIN_PASSWORD}

[smtp]
enabled = true
host = ${SMTP_HOST}
user = ${SMTP_USER}
password = ${SMTP_PASSWORD}
from_address = ${SMTP_FROM}
from_name = ${SMTP_FROM_NAME}
skip_verify = false
EOF

# ------------------------------------------------------------------
# Configure Prometheus
# ------------------------------------------------------------------
echo "==> Writing prometheus.yml"
SCRAPE_CONFIGS="  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:${PROMETHEUS_PORT}']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:${NODE_EXPORTER_PORT}']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['localhost:${CADVISOR_PORT}']"

if [ "$GPU_EXPORTER_INSTALLED" = "1" ]; then
SCRAPE_CONFIGS="${SCRAPE_CONFIGS}

  - job_name: 'nvidia_gpu_exporter'
    static_configs:
      - targets: ['localhost:${NVIDIA_EXPORTER_PORT}']"
fi

sudo tee /etc/prometheus/prometheus.yml > /dev/null << EOF
global:
  scrape_interval: 15s

scrape_configs:
${SCRAPE_CONFIGS}
EOF

echo "==> Setting Prometheus listen port to ${PROMETHEUS_PORT} (/etc/default/prometheus)"
if [ -f /etc/default/prometheus ]; then
    sudo sed -i '/^ARGS=/d' /etc/default/prometheus
fi
echo "ARGS=\"--web.listen-address=0.0.0.0:${PROMETHEUS_PORT}\"" | sudo tee -a /etc/default/prometheus > /dev/null

# ------------------------------------------------------------------
# Start services
# ------------------------------------------------------------------
echo "==> Enabling and starting services"
sudo systemctl daemon-reload
sudo systemctl enable --now grafana-server
sudo systemctl enable --now prometheus
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl restart grafana-server   # picks up the appended grafana.ini

GRAFANA_URL="http://localhost:${GRAFANA_PORT}"
PROMETHEUS_URL="http://localhost:${PROMETHEUS_PORT}"

echo "==> Waiting for Grafana and Prometheus to become ready..."
GRAFANA_READY=0
PROM_READY=0
for i in $(seq 1 60); do
    curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1 && GRAFANA_READY=1
    curl -sf "${PROMETHEUS_URL}/-/ready" > /dev/null 2>&1 && PROM_READY=1
    if [ "$GRAFANA_READY" = "1" ] && [ "$PROM_READY" = "1" ]; then
        echo "    Both services ready."
        break
    fi
    sleep 2
done

if [ "$GRAFANA_READY" != "1" ]; then
    echo "    ⚠️  Grafana did not respond on ${GRAFANA_URL}/api/health after 120s."
    echo "    ---- systemctl status grafana-server ----"
    sudo systemctl status grafana-server --no-pager || true
    echo "    ---- last 40 log lines ----"
    sudo journalctl -u grafana-server -n 40 --no-pager || true
    echo ""
    echo "Fix whatever's shown above, confirm it's up with:"
    echo "  curl -s ${GRAFANA_URL}/api/health"
    echo "then re-run this script — it's safe to re-run, it checks before creating anything."
    exit 1
fi

if [ "$PROM_READY" != "1" ]; then
    echo "    ⚠️  Prometheus did not respond on ${PROMETHEUS_URL}/-/ready after 120s."
    echo "    ---- systemctl status prometheus ----"
    sudo systemctl status prometheus --no-pager || true
    echo "    ---- last 40 log lines ----"
    sudo journalctl -u prometheus -n 40 --no-pager || true
    exit 1
fi

echo "==> Adding Prometheus datasource via API"
DS_RESPONSE=$(curl -s -X POST "${GRAFANA_URL}/api/datasources" \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Prometheus\",
    \"type\": \"prometheus\",
    \"url\": \"${PROMETHEUS_URL}\",
    \"access\": \"proxy\",
    \"isDefault\": true
  }")

DS_UID=$(echo "$DS_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('datasource',{}).get('uid',''))" 2>/dev/null || echo "")

if [ -z "$DS_UID" ]; then
    echo "    Datasource may already exist — fetching existing UID..."
    DS_UID=$(curl -s "${GRAFANA_URL}/api/datasources" -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['uid'] if d else '')")
fi

echo "    Datasource UID: $DS_UID"

AUTH="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
API="${GRAFANA_URL}"

echo "==> Creating/reusing folder 'System Monitoring'"
FOLDER_UID=$(curl -s "${API}/api/folders" -u "$AUTH" | python3 -c "
import json,sys
folders = json.load(sys.stdin)
match = [f for f in folders if f.get('title') == 'System Monitoring']
print(match[0]['uid'] if match else '')
")
if [ -z "$FOLDER_UID" ]; then
    FOLDER_UID=$(curl -s -X POST "${API}/api/folders" -u "$AUTH" \
      -H "Content-Type: application/json" \
      -d '{"title":"System Monitoring"}' | python3 -c "import json,sys; print(json.load(sys.stdin).get('uid',''))")
fi
echo "    Folder UID: $FOLDER_UID"

echo "==> Creating/reusing contact point 'email receiver' (UI-editable, not provisioned-locked)"
CP_UID=$(curl -s "${API}/api/v1/provisioning/contact-points" -u "$AUTH" | python3 -c "
import json,sys
cps = json.load(sys.stdin)
match = [c for c in cps if c.get('name') == 'email receiver']
print(match[0]['uid'] if match else '')
")
if [ -z "$CP_UID" ]; then
    CP_UID=$(python3 -c "
import json
print(json.dumps({
    'name': 'email receiver',
    'type': 'email',
    'settings': {'addresses': '${ALERT_EMAILS}'},
    'disableResolveMessage': False
}))
" | curl -s -X POST "${API}/api/v1/provisioning/contact-points" -u "$AUTH" \
      -H "Content-Type: application/json" \
      -H "X-Disable-Provenance: true" \
      -d @- | python3 -c "import json,sys; print(json.load(sys.stdin).get('uid',''))")
fi
echo "    Contact point UID: $CP_UID"

echo "==> Setting default notification policy to 'email receiver'"
curl -s "${API}/api/v1/provisioning/policies" -u "$AUTH" | python3 -c "
import json,sys
policy = json.load(sys.stdin)
policy['receiver'] = 'email receiver'
policy['group_by'] = ['alertname', 'instance']
print(json.dumps(policy))
" | curl -s -X PUT "${API}/api/v1/provisioning/policies" -u "$AUTH" \
    -H "Content-Type: application/json" \
    -H "X-Disable-Provenance: true" \
    -d @- > /dev/null

echo "==> Creating alert rules via API (UI-editable — thresholds default to 80%, change anytime from the UI)"

create_or_update_rule() {
    local rule_uid="$1"
    local payload="$2"
    local status
    status=$(curl -s -o /tmp/rule_response.json -w "%{http_code}" \
      -X PUT "${API}/api/v1/provisioning/alert-rules/${rule_uid}" -u "$AUTH" \
      -H "Content-Type: application/json" \
      -H "X-Disable-Provenance: true" \
      -d "$payload")
    if [ "$status" = "404" ]; then
        status=$(curl -s -o /tmp/rule_response.json -w "%{http_code}" \
          -X POST "${API}/api/v1/provisioning/alert-rules" -u "$AUTH" \
          -H "Content-Type: application/json" \
          -H "X-Disable-Provenance: true" \
          -d "$payload")
    fi
    if [[ "$status" =~ ^2 ]]; then
        echo "    ✅ $rule_uid ($status)"
    else
        echo "    ⚠️  $rule_uid failed ($status) — see /tmp/rule_response.json"
    fi
}

# Values are passed via environment variables (not interpolated into the
# heredoc text) so that quotes/special characters inside descriptions,
# expressions, etc. can never break the Python source.
build_rule() {
    RULE_UID="$1" RULE_TITLE="$2" RULE_EXPR="$3" RULE_THRESHOLD="$4" \
    RULE_FOR="$5" RULE_SUMMARY="$6" RULE_DESCRIPTION="$7" RULE_LABELS="$8" \
    RULE_OP="${9:-gt}" RULE_NODATA="${10:-NoData}" \
    RULE_FOLDER_UID="$FOLDER_UID" RULE_DS_UID="$DS_UID" \
    python3 << 'PYEOF'
import json, os

uid = os.environ["RULE_UID"]
title = os.environ["RULE_TITLE"]
expr = os.environ["RULE_EXPR"]
threshold = float(os.environ["RULE_THRESHOLD"])
for_duration = os.environ["RULE_FOR"]
summary = os.environ["RULE_SUMMARY"]
description = os.environ["RULE_DESCRIPTION"]
labels = json.loads(os.environ["RULE_LABELS"])
folder_uid = os.environ["RULE_FOLDER_UID"]
ds_uid = os.environ["RULE_DS_UID"]
op = os.environ.get("RULE_OP", "gt")            # gt = above threshold, lt = below
no_data = os.environ.get("RULE_NODATA", "NoData")

rule = {
    "uid": uid,
    "title": title,
    "ruleGroup": "System Resource Alerts",
    "folderUID": folder_uid,
    "condition": "C",
    "data": [
        {
            "refId": "A",
            "datasourceUid": ds_uid,
            "relativeTimeRange": {"from": 300, "to": 0},
            "model": {"expr": expr, "interval": "1m", "refId": "A"}
        },
        {
            "refId": "B",
            "datasourceUid": "__expr__",
            "relativeTimeRange": {"from": 300, "to": 0},
            "model": {"type": "reduce", "refId": "B", "expression": "A", "reducer": "last", "settings": {"mode": "dropNN"}}
        },
        {
            "refId": "C",
            "datasourceUid": "__expr__",
            "relativeTimeRange": {"from": 300, "to": 0},
            "model": {
                "type": "threshold", "refId": "C", "expression": "B",
                "conditions": [{
                    "evaluator": {"params": [threshold], "type": op},
                    "operator": {"type": "and"},
                    "query": {"params": ["C"]},
                    "reducer": {"params": [], "type": "last"},
                    "type": "query"
                }]
            }
        }
    ],
    "noDataState": no_data,
    "execErrState": "Alerting",
    "for": for_duration,
    "annotations": {"summary": summary, "description": description},
    "labels": labels,
    "isPaused": False,
    "notification_settings": {"receiver": "email receiver"}
}
print(json.dumps(rule))
PYEOF
}

CPU_PAYLOAD=$(build_rule "high_cpu_usage" "High CPU Usage Alert" \
  "100 - round((avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)) * on(instance) group_left(nodename) node_uname_info" \
  "$CPU_THRESHOLD" "5m" \
  "🚨 High CPU Usage Detected" \
  "CPU usage is {{ printf \"%.2f\" \$values.B.Value }}% on {{ \$labels.nodename }} ({{ \$labels.instance }})."$'\n'"${ALERT_FOOTER}" \
  '{"severity":"warning","alert_type":"cpu","team":"infrastructure"}')
create_or_update_rule "high_cpu_usage" "$CPU_PAYLOAD"

RAM_PAYLOAD=$(build_rule "high_ram_usage" "High RAM Usage Alert" \
  "round((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100) * on(instance) group_left(nodename) node_uname_info" \
  "$RAM_THRESHOLD" "5m" \
  "🚨 High RAM Usage Detected" \
  "RAM usage is {{ printf \"%.2f\" \$values.B.Value }}% on {{ \$labels.nodename }} ({{ \$labels.instance }})."$'\n'"${ALERT_FOOTER}" \
  '{"severity":"warning","alert_type":"memory","team":"infrastructure"}')
create_or_update_rule "high_ram_usage" "$RAM_PAYLOAD"

DISK_PAYLOAD=$(build_rule "high_disk_usage" "High Disk Usage Alert" \
  "round(((node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|squashfs|vfat|fuse.*\"} - node_filesystem_free_bytes{fstype!~\"tmpfs|overlay|squashfs|vfat|fuse.*\"}) / (node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|squashfs|vfat|fuse.*\"} > 0) * 100) * on(instance) group_left(nodename) node_uname_info, 0.01)" \
  "$DISK_THRESHOLD" "1m" \
  "🚨 High Disk Usage Detected" \
  "Disk usage is {{ printf \"%.2f\" \$values.B.Value }}% on {{ \$labels.nodename }} ({{ \$labels.instance }})."$'\n'"${ALERT_FOOTER}" \
  '{"severity":"warning","alert_type":"disk","team":"infrastructure"}')
create_or_update_rule "high_disk_usage" "$DISK_PAYLOAD"

# GPU metric comes from a different scrape target (nvidia_gpu_exporter,
# not node_exporter) so its "instance" label won't match node_uname_info's
# — no group_left join here, we use the exporter's own "name" (GPU model)
# label instead.
if [ "$GPU_EXPORTER_INSTALLED" = "1" ]; then
GPU_PAYLOAD=$(build_rule "high_gpu_usage" "High GPU Usage Alert" \
  "nvidia_smi_utilization_gpu_ratio * 100" \
  "$GPU_THRESHOLD" "5m" \
  "🚨 High GPU Usage Detected" \
  "GPU usage is {{ printf \"%.2f\" \$values.B.Value }}% on {{ \$labels.name }} ({{ \$labels.instance }})."$'\n'"${ALERT_FOOTER}" \
  '{"severity":"warning","alert_type":"gpu","team":"infrastructure"}')
create_or_update_rule "high_gpu_usage" "$GPU_PAYLOAD"
else
    echo "    ⏭️  Skipping High GPU Usage Alert — no nvidia_gpu_exporter installed on this host"
fi

# System Down — query: up{job="node_exporter"}, condition: Is Below 1,
# pending period 2m (avoids false positives from brief network blips).
# No node_uname_info join here: if the host is down that series goes stale
# and the join would silently drop the very alert we want. If the series
# disappears entirely we also treat "no data" as down.
DOWN_PAYLOAD=$(build_rule "system_down" "System Down Alert" \
  'up{job="node_exporter"}' \
  "1" "2m" \
  "🚨 System Down" \
  "node_exporter on {{ \$labels.instance }} is not responding — the system may be down."$'\n'"${ALERT_FOOTER}" \
  '{"severity":"critical","alert_type":"down","team":"infrastructure"}' \
  "lt" "Alerting")
create_or_update_rule "system_down" "$DOWN_PAYLOAD"

echo ""
echo "    Rules created via API with X-Disable-Provenance — fully editable from the Grafana UI."
if [ "$GPU_EXPORTER_INSTALLED" = "1" ]; then
    echo "    Default thresholds: CPU ${CPU_THRESHOLD}%, RAM ${RAM_THRESHOLD}%, Disk ${DISK_THRESHOLD}%, GPU ${GPU_THRESHOLD}%"
else
    echo "    Default thresholds: CPU ${CPU_THRESHOLD}%, RAM ${RAM_THRESHOLD}%, Disk ${DISK_THRESHOLD}% (GPU rule skipped — no GPU exporter)"
fi

# ------------------------------------------------------------------
# Dashboard: CPU / RAM / Disk / GPU + Top 5 Docker containers by CPU
# ------------------------------------------------------------------
echo "==> Creating/updating dashboard 'System Monitoring Overview'"
DASHBOARD_JSON=$(DS_UID="$DS_UID" FOLDER_UID="$FOLDER_UID" python3 << 'PYEOF'
import json, os

ds = os.environ["DS_UID"]
folder_uid = os.environ["FOLDER_UID"]

def ds_ref():
    return {"type": "prometheus", "uid": ds}

def ts_panel(id_, title, expr, x, y, w=12, h=8, unit="percent"):
    return {
        "id": id_, "title": title, "type": "timeseries",
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "datasource": ds_ref(),
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "targets": [{"expr": expr, "refId": "A", "datasource": ds_ref()}]
    }

panels = [
    ts_panel(1, "CPU Usage %", '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)', 0, 0),
    ts_panel(2, "RAM Usage %", '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100', 12, 0),
    ts_panel(3, "Disk Usage % (/)", '(1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100', 0, 8),
    ts_panel(4, "GPU Utilization % (if GPU present)", 'nvidia_smi_utilization_gpu_ratio * 100', 12, 8),
    {
        "id": 5, "title": "Top 5 Docker Containers by CPU %", "type": "bargauge",
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 16},
        "datasource": ds_ref(),
        "fieldConfig": {"defaults": {"unit": "percent"}, "overrides": []},
        "options": {"orientation": "horizontal", "displayMode": "gradient"},
        "targets": [{
            "expr": 'topk(5, sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[1m])) * 100)',
            "refId": "A", "legendFormat": "{{name}}",
            "datasource": ds_ref()
        }]
    }
]

dashboard = {
    "dashboard": {
        "uid": "system-monitoring-overview",
        "title": "System Monitoring Overview",
        "tags": ["system", "auto-generated"],
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 0,
        "refresh": "30s",
        "time": {"from": "now-1h", "to": "now"},
        "panels": panels
    },
    "folderUid": folder_uid,
    "overwrite": True
}
print(json.dumps(dashboard))
PYEOF
)

DASH_RESULT=$(curl -s -X POST "${API}/api/dashboards/db" -u "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$DASHBOARD_JSON")
DASH_URL=$(echo "$DASH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null || echo "")
if [ -n "$DASH_URL" ]; then
    echo "    Dashboard ready: ${GRAFANA_URL}${DASH_URL}"
else
    echo "    ⚠️  Dashboard creation may have failed — check Alerting → Dashboards in the UI. Response:"
    echo "    $DASH_RESULT"
fi

# ------------------------------------------------------------------
# Import custom dashboards (JSON files sitting next to this script)
#   1. cadvisor dashboard.json
#   2. Node Exporter Full.json
# Handles both "export for sharing externally" files (__inputs /
# ${DS_PROMETHEUS}) and plain exports. Re-running overwrites in place.
# ------------------------------------------------------------------
import_dashboard() {
    local label="$1"; shift
    local file="" pattern payload result url

    for pattern in "$@"; do
        file=$(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname "$pattern" | head -1)
        [ -n "$file" ] && break
    done
    if [ -z "$file" ]; then
        echo "    ⏭️  ${label}: JSON not found in ${SCRIPT_DIR} (looked for: $*) — skipping"
        return 0
    fi

    if ! payload=$(DASH_FILE="$file" DS_UID="$DS_UID" FOLDER_UID="$FOLDER_UID" python3 << 'PYEOF'
import json, os

with open(os.environ["DASH_FILE"], encoding="utf-8") as f:
    d = json.load(f)

# Some exports are wrapped as {"dashboard": {...}}
if isinstance(d.get("dashboard"), dict):
    d = d["dashboard"]

ds_uid = os.environ["DS_UID"]

inputs = []
for i in d.get("__inputs", []):
    if i.get("type") == "datasource":
        inputs.append({"name": i["name"], "type": "datasource",
                       "pluginId": i.get("pluginId", "prometheus"), "value": ds_uid})
    else:
        inputs.append({"name": i["name"], "type": i.get("type", "constant"),
                       "value": i.get("value", "")})

d["id"] = None
body = json.dumps({"dashboard": d, "overwrite": True, "inputs": inputs,
                   "folderUid": os.environ["FOLDER_UID"]})

# Plain export that still references ${DS_PROMETHEUS}: point it at our datasource
if not inputs:
    body = body.replace("${DS_PROMETHEUS}", ds_uid)

print(body)
PYEOF
    ); then
        echo "    ⚠️  ${label}: could not parse ${file} (invalid JSON?) — skipping"
        return 0
    fi

    result=$(curl -s -X POST "${API}/api/dashboards/import" -u "$AUTH" \
      -H "Content-Type: application/json" -d "$payload")
    url=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('importedUrl',''))" 2>/dev/null || echo "")
    if [ -n "$url" ]; then
        echo "    ✅ ${label}: ${GRAFANA_URL}${url}"
        IMPORTED_DASHBOARDS="${IMPORTED_DASHBOARDS}
   ${label}: ${GRAFANA_URL}${url}"
    else
        echo "    ⚠️  ${label}: import failed. Response: ${result}"
    fi
}

echo "==> Importing custom dashboards from ${SCRIPT_DIR}"
IMPORTED_DASHBOARDS=""
import_dashboard "cAdvisor" "cadvisor dashboard.json" "cadvisor*.json"
import_dashboard "Node Exporter Full" "Node Exporter Full.json" "node*exporter*full*.json"

echo "==> Waiting for Grafana to come back up..."
for i in $(seq 1 20); do
    if curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

echo ""
echo "============================================================"
echo " Setup complete on $(hostname) ($HOST_IP)"
echo "============================================================"
echo " Grafana:        http://${HOST_IP}:${GRAFANA_PORT}  (login: ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD})"
echo " Prometheus:      http://${HOST_IP}:${PROMETHEUS_PORT}"
echo " node_exporter:   http://${HOST_IP}:${NODE_EXPORTER_PORT}/metrics"
echo " cAdvisor:        http://${HOST_IP}:${CADVISOR_PORT}"
if [ "$GPU_EXPORTER_INSTALLED" = "1" ]; then
echo " nvidia_gpu_exp:  http://${HOST_IP}:${NVIDIA_EXPORTER_PORT}/metrics"
else
echo " nvidia_gpu_exp:  (skipped — no GPU detected)"
fi
echo " Datasource UID: ${DS_UID}"
echo " Dashboard:       ${GRAFANA_URL}${DASH_URL:-/dashboards (check UI)}"
if [ -n "$IMPORTED_DASHBOARDS" ]; then
echo " Imported dashboards:${IMPORTED_DASHBOARDS}"
fi
echo ""
echo " Services:   systemctl status grafana-server prometheus prometheus-node-exporter"
echo " Containers: docker ps --filter name=cadvisor"
echo " Verify targets: curl -s http://localhost:${PROMETHEUS_PORT}/api/v1/targets | python3 -m json.tool"
echo " Verify alerts loaded: Alerting → Alert rules in the Grafana UI (should show 5 rules, or 4 if no GPU exporter — none tagged 'Provisioned')"
echo "============================================================"
