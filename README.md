# Grafana Setup Native

Automated, native Linux installation of a monitoring stack built around **Grafana**, **Prometheus**, and **Node Exporter**. The core services run under `systemd`; Docker is used only for cAdvisor because it needs access to the Docker daemon.

The installer also:

- Configures Grafana SMTP notifications.
- Creates a Prometheus data source and a `System Monitoring` folder.
- Creates editable CPU, memory, disk, system-down, and—when available—GPU alert rules.
- Creates a system overview dashboard.
- Imports the included cAdvisor and Node Exporter dashboards.
- Detects NVIDIA hardware and installs `nvidia_gpu_exporter` only when a working `nvidia-smi` is available.

## Components and default ports

| Component | Port | Deployment |
| --- | ---: | --- |
| Grafana | `3001` | Native `systemd` service |
| Prometheus | `9091` | Native `systemd` service |
| Node Exporter | `9100` | Native `systemd` service |
| cAdvisor | `8081` | Docker container |
| NVIDIA GPU Exporter | `9836` | Optional native `systemd` service |

The non-default ports are intentional and can be changed near the top of `auto-grafana-installer.sh` if they conflict with services already running on the host.

## Requirements

- Ubuntu or another Debian-based Linux distribution with `apt` and `systemd`.
- `sudo` access.
- Internet access for package, dashboard, and exporter downloads.
- Python 3, `curl`, `wget`, and `gnupg` (the installer installs missing prerequisites).
- Docker is installed automatically if it is not already available, and is used only for cAdvisor.
- For GPU monitoring: an NVIDIA GPU with a working NVIDIA driver and `nvidia-smi`. The installer does **not** install or modify NVIDIA drivers or CUDA.

## Quick start

Clone the repository and run the installer from the repository directory so the bundled dashboard JSON files can be found:

```bash
git clone https://github.com/vaibhav-dev19/grafana-setup-native.git
cd grafana-setup-native
chmod +x *.sh
sudo ./auto-grafana-installer.sh
```

During installation you will be prompted for:

- SMTP sender address and app password.
- Comma-separated alert recipients.
- An optional name for the monitored system.

After completion, open:

- Grafana: `http://<host-ip>:3001`
- Prometheus: `http://<host-ip>:9091`
- Node Exporter metrics: `http://<host-ip>:9100/metrics`
- cAdvisor: `http://<host-ip>:8081`
- NVIDIA exporter metrics, when installed: `http://<host-ip>:9836/metrics`

The default Grafana credentials currently defined by the installer are `admin` / `root@1234`. **Change the password immediately after the first login and do not expose Grafana directly to the public internet.**

## Configuration

Defaults are defined at the beginning of [`auto-grafana-installer.sh`](auto-grafana-installer.sh), including:

- Grafana, Prometheus, Node Exporter, cAdvisor, and GPU exporter ports.
- Grafana administrator credentials.
- Default CPU, RAM, disk, and GPU alert thresholds (`80%`).
- SMTP host and alert recipients.

The script writes Grafana configuration to `/etc/grafana/grafana.ini` and Prometheus configuration to `/etc/prometheus/prometheus.yml`. Alert rules are created through the Grafana API and remain editable from the Grafana UI.

> **Security:** Do not commit real SMTP passwords, Grafana passwords, or recipient data. The current script contains placeholder/default credentials for interactive use; review and secure these values before deploying it.

## Verify the installation

Run the diagnostic script to inspect services, processes, packages, Docker containers, configuration directories, ports, and NVIDIA GPU availability:

```bash
chmod +x check_monitoring_stack.sh
sudo ./check_monitoring_stack.sh
```

Useful manual checks:

```bash
sudo systemctl status grafana-server prometheus prometheus-node-exporter --no-pager
sudo docker ps --filter name=cadvisor
curl -s http://localhost:9091/api/v1/targets | python3 -m json.tool
curl -s http://localhost:3001/api/health
```

## Monitoring operations and troubleshooting

The following commands are grouped by task. Run them from an administrative shell where needed. Service names can vary by package or distribution; this project normally uses `prometheus-node-exporter`, while some custom installations use `node_exporter`.

### 1. Check Grafana SMTP/mail configuration

Inspect the non-secret SMTP settings configured in Grafana:

```bash
sudo grep -E '^\\s*(enabled|host|user|from_address|from_name|startTLS_policy)' /etc/grafana/grafana.ini
```

Search Grafana configuration and provisioning files for SMTP-related settings. This command can expose passwords, so review the output locally and **never paste secrets into an issue, chat, or support request**:

```bash
sudo grep -RniE 'smtp|from_address|from_name|startTLS|password' /etc/grafana 2>/dev/null
```

Show the SMTP section from the main configuration file:

```bash
sudo sed -n '/^\\[smtp\\]/,/^\\[/p' /etc/grafana/grafana.ini
```

Confirm that an SMTP section exists in the effective Grafana configuration file:

```bash
sudo grep -ni '^\\[smtp\\]' /etc/grafana/grafana.ini
```

The installer uses `smtp.gmail.com:465` with implicit TLS. If mail is not being delivered, also check the Grafana logs:

```bash
sudo journalctl -u grafana-server -n 100 --no-pager
sudo journalctl -u grafana-server -f
```

### 2. Check installed services, running services, processes, and ports

```bash
systemctl list-unit-files | grep -Ei 'grafana|prometheus|node.exporter|node_exporter|cadvisor|nvidia.*exporter'
systemctl list-units --type=service --all | grep -Ei 'grafana|prometheus|node.exporter|node_exporter|cadvisor|nvidia.*exporter'
ps aux | grep -Ei '[g]rafana|[p]rometheus|[n]ode_exporter|[c]advisor|[n]vidia.*exporter'
sudo ss -lntp | grep -E ':(3001|9091|9100|8081|9836)\\b'
```

Expected project ports are:

| Port | Service |
| ---: | --- |
| `3001` | Grafana |
| `9091` | Prometheus |
| `9100` | Node Exporter |
| `8081` | cAdvisor |
| `9836` | NVIDIA GPU Exporter, when installed |

### 3. Manage Grafana, Prometheus, and Node Exporter

Check service status:

```bash
sudo systemctl status grafana-server --no-pager
sudo systemctl status prometheus --no-pager
sudo systemctl status prometheus-node-exporter --no-pager
# If your installation uses a custom unit:
sudo systemctl status node_exporter --no-pager
```

Start, stop, restart, enable, or disable the services. Use the service name that exists on your host:

```bash
sudo systemctl start grafana-server prometheus prometheus-node-exporter
sudo systemctl stop grafana-server prometheus prometheus-node-exporter
sudo systemctl restart grafana-server prometheus prometheus-node-exporter
sudo systemctl enable grafana-server prometheus prometheus-node-exporter
sudo systemctl disable grafana-server prometheus prometheus-node-exporter
```

View Grafana logs:

```bash
sudo journalctl -u grafana-server -f
sudo journalctl -u grafana-server -n 100 --no-pager
```

### 4. Remove the monitoring stack

Use this only when you want to completely remove Grafana, Prometheus, and Node Exporter. The repository includes a teardown script:

```bash
sudo ./teardown.sh
```

If you need to remove components manually, first stop and disable the services:

```bash
sudo systemctl stop grafana-server prometheus prometheus-node-exporter
sudo systemctl disable grafana-server prometheus prometheus-node-exporter
```

Then remove packages and configuration only after confirming that the data is no longer needed:

```bash
sudo apt purge -y grafana prometheus prometheus-node-exporter
sudo apt autoremove -y
sudo systemctl daemon-reload
sudo rm -rf /etc/grafana /etc/prometheus /var/lib/grafana /var/lib/prometheus
```

> **Warning:** Deleting `/var/lib/grafana` and `/var/lib/prometheus` removes dashboards, Grafana state, and Prometheus time-series data. Do not remove custom systemd files or users unless you created them specifically for this installation and have verified they are no longer needed.

### 5. cAdvisor

Check for a cAdvisor process and Docker container:

```bash
ps aux | grep -i '[c]advisor'
sudo docker ps -a | grep -i cadvisor
systemctl list-unit-files | grep -Ei 'cadvisor|cAdvisor'
```

The installer runs cAdvisor as a Docker container. Stop and remove it with:

```bash
sudo docker rm -f cadvisor
```

To remove the image as well:

```bash
sudo docker rmi gcr.io/cadvisor/cadvisor:latest
```

If you find a separate native cAdvisor process, identify its actual PID before stopping it:

```bash
pgrep -af cadvisor
sudo kill <actual-pid>
```

### 6. NVIDIA GPU and GPU exporter

The installer never installs, upgrades, or modifies the NVIDIA driver or CUDA toolkit.

```bash
nvidia-smi
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
nvcc --version
sudo ss -lntp | grep -E ':9836\\b'
ps aux | grep -Ei '[n]vidia.*exporter|[g]pu.*exporter'
sudo docker ps -a | grep -Ei 'nvidia.*exporter|gpu.*exporter'
```

Removing Grafana, Prometheus, or cAdvisor does not remove the NVIDIA driver or GPU installation.

### 7. Docker commands

```bash
docker ps
docker ps -a
sudo docker ps -a --format 'table {{.Names}}\\t{{.Image}}\\t{{.Ports}}'
sudo docker stop <container_name>
sudo docker rm <container_name>
sudo docker rm -f <container_name>
docker images
sudo docker rmi <image_id>
sudo systemctl status docker --no-pager
```

Do not remove Docker itself unless you specifically want to uninstall Docker.

### 8. APT and repository troubleshooting

```bash
sudo apt update
sudo apt upgrade
sudo apt autoremove
grep -Rni 'ubuntuubuntu22.04' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
ls -la /etc/apt/sources.list.d/ | grep -i nvidia
```

If a specific broken NVIDIA repository is confirmed, remove only that entry and retry:

```bash
sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
```

Do not delete all NVIDIA repositories blindly. Inspect the exact broken entry first.

### 9. Mouse and GUI troubleshooting

```bash
echo "$XDG_SESSION_TYPE"
echo "$DISPLAY"
xinput list
xinput disable <device-id>
xinput enable <device-id>
systemctl status display-manager
```

Restarting GDM3 can log you out and close graphical applications:

```bash
sudo systemctl restart gdm3
```

To restart the system:

```bash
sudo reboot
```

### 10. General Linux commands

| Command | Description |
| --- | --- |
| `pwd` | Show the current directory |
| `ls -la` | List all files, including hidden files |
| `cd <directory>` | Change directory |
| `df -h` | Check disk space |
| `du -sh <directory>` | Check directory size |
| `free -h` | Check RAM usage |
| `top` | Monitor processes |
| `htop` | Interactive process monitor |
| `ps aux` | List processes |
| `ip addr` | Show network interfaces and addresses |
| `ping <IP>` | Test network connectivity |
| `systemctl status <service>` | Check service status |
| `journalctl -u <service>` | View service logs |
| `which <command>` | Find a command |
| `history` | Show shell history |

## Recommended workflow

1. **Check:** Run `sudo ./check_monitoring_stack.sh`.
2. **Inspect:** Review services, processes, Docker containers, ports, configuration, and logs.
3. **Change:** Stop, install, or remove only the required components.
4. **Verify:** Run the check script again after making changes.

## Repository contents

- [`auto-grafana-installer.sh`](auto-grafana-installer.sh) — installs and configures the monitoring stack.
- [`check_monitoring_stack.sh`](check_monitoring_stack.sh) — reports installation and runtime status.
- [`teardown.sh`](teardown.sh) — stops the stack and optionally removes packages and data.
- [`Node Exporter Full.json`](Node%20Exporter%20Full.json) — Grafana Node Exporter dashboard.
- [`cadvisor dashboard.json`](cadvisor%20dashboard.json) — Grafana cAdvisor dashboard.

## Notes

- The installer is designed to be re-runnable and attempts to reuse existing Grafana resources.
- cAdvisor requires Docker and mounts host paths so it can collect container metrics.
- GPU alerting and the GPU dashboard query are skipped when no working NVIDIA exporter is detected.
- Review firewall rules before exposing ports beyond localhost or a trusted monitoring network.
- Save this guide as `ubuntu-monitoring-commands.md` if you want a reusable command cheat sheet for other machines.
