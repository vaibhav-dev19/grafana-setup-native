#!/bin/bash

echo "===== SERVICES ====="
systemctl list-unit-files | grep -Ei 'grafana|prometheus|node.exporter|cadvisor|nvidia.*exporter|gpu.*exporter' || echo "NONE"

echo
echo "===== RUNNING SERVICES ====="
systemctl list-units --type=service --all | grep -Ei 'grafana|prometheus|node.exporter|cadvisor|nvidia.*exporter|gpu.*exporter' || echo "NONE"

echo
echo "===== PROCESSES ====="
ps aux | grep -Ei '[g]rafana|[p]rometheus|[n]ode_exporter|[c]advisor|[n]vidia.*exporter|[g]pu.*exporter' || echo "NONE"

echo
echo "===== DOCKER ====="
sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null | grep -Ei 'grafana|prometheus|node.exporter|cadvisor|nvidia.*exporter|gpu.*exporter' || echo "NONE"

echo
echo "===== PACKAGES ====="
dpkg -l 2>/dev/null | grep -Ei 'grafana|prometheus|node-exporter|cadvisor|nvidia.*exporter|gpu.*exporter' || echo "NONE"

echo
echo "===== CONFIG/DATA DIRECTORIES ====="
sudo ls -ld \
/etc/grafana \
/etc/prometheus \
/var/lib/grafana \
/var/lib/prometheus \
/opt/node_exporter \
/opt/cadvisor \
/opt/nvidia_gpu_exporter \
/etc/nvidia_gpu_exporter \
/var/lib/nvidia_gpu_exporter \
2>/dev/null || true

echo
echo "===== GPU EXPORTER PORT ====="
sudo ss -lntp 2>/dev/null | grep -E ':9835\b' || echo "PORT 9835 NOT LISTENING"

echo
echo "===== NVIDIA GPU ====="
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo "NVIDIA-SMI NOT AVAILABLE"
