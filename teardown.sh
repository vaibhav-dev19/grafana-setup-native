#!/bin/bash
set -euo pipefail

# ============================================================
# Grafana Monitoring Stack — Teardown (native services)
# Stops/disables the systemd services and optionally purges
# packages + all data (dashboards, alert history, metrics).
# ============================================================

SERVICES=(grafana-server prometheus prometheus-node-exporter nvidia_gpu_exporter)
PACKAGES=(grafana prometheus prometheus-node-exporter nvidia_gpu_exporter)
DATA_PATHS=(/etc/grafana /var/lib/grafana /etc/prometheus /var/lib/prometheus /etc/default/prometheus)
REPO_PATHS=(/etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg)

echo "============================================================"
echo " Grafana Monitoring Teardown (native services)"
echo "============================================================"
echo ""
echo "This will stop and disable: ${SERVICES[*]}"
echo ""

read -rp "Also PURGE packages and DELETE all data (dashboards, alert history, metrics)? [y/N]: " DELETE_DATA
DELETE_DATA="${DELETE_DATA:-N}"

read -rp "Type 'yes' to confirm teardown: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted — nothing was changed."
    exit 0
fi

echo "==> Stopping and disabling services"
for s in "${SERVICES[@]}"; do
    if systemctl list-unit-files --type=service | grep -q "^${s}\.service"; then
        echo "    Stopping $s"
        sudo systemctl stop "$s" 2>/dev/null || true
        sudo systemctl disable "$s" 2>/dev/null || true
    fi
done

echo "==> Removing cAdvisor container (Docker itself is left untouched)"
if command -v docker &> /dev/null && sudo docker ps -a --format '{{.Names}}' | grep -qx cadvisor; then
    sudo docker rm -f cadvisor > /dev/null
    echo "    Removed container: cadvisor"
else
    echo "    No cadvisor container found"
fi

if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
    echo "==> Purging packages: ${PACKAGES[*]}"
    sudo apt-get purge -y "${PACKAGES[@]}" || true
    sudo apt-get autoremove -y || true

    echo "==> Deleting config/data directories"
    for p in "${DATA_PATHS[@]}" "${REPO_PATHS[@]}"; do
        if [ -e "$p" ]; then
            echo "    Removing: $p"
            sudo rm -rf "$p"
        fi
    done
    sudo apt-get update

    echo "    Removed: dashboards, alert rules, metrics history, provisioning config, apt repo"
else
    echo "==> Packages and data preserved"
    echo "    (grafana, prometheus, prometheus-node-exporter packages still installed;"
    echo "     /etc/grafana, /var/lib/grafana, /etc/prometheus, /var/lib/prometheus all kept)"
    echo "    Re-enable later with: sudo systemctl enable --now grafana-server prometheus prometheus-node-exporter"
fi

echo ""
echo "==> Verifying services are stopped"
ANY_RUNNING=0
for s in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
        echo "    ⚠️  $s is still running — check manually"
        ANY_RUNNING=1
    fi
done
[ "$ANY_RUNNING" -eq 0 ] && echo "    ✅ Confirmed: no grafana/prometheus/node-exporter services running"

echo ""
echo "============================================================"
echo " Teardown complete."
echo "============================================================"
