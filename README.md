# Grafana Setup Native

Automated, native Linux installation of a monitoring stack built around **Grafana**, **Prometheus**, and **Node Exporter**. The core services run under `systemd`; Docker is used only for cAdvisor because cAdvisor needs access to the Docker daemon to inspect containers.

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

> **Security:** Do not commit real SMTP passwords, Grafana passwords, or recipient data. The current script contains placeholder/default credentials for interactive use; review and secure these values before production deployment. Prefer a protected secrets mechanism and a reverse proxy with TLS and authentication for external access.

## Verify the installation

Run the diagnostic script to inspect services, processes, packages, Docker containers, configuration directories, ports, and NVIDIA GPU availability:

```bash
sudo ./check_monitoring_stack.sh
```

Useful manual checks:

```bash
sudo systemctl status grafana-server prometheus prometheus-node-exporter
sudo docker ps --filter name=cadvisor
curl -s http://localhost:9091/api/v1/targets | python3 -m json.tool
curl -s http://localhost:3001/api/health
```

## Remove the stack

Run the teardown script:

```bash
sudo ./teardown.sh
```

The script always stops and disables the monitoring services and removes the `cadvisor` container. It leaves Docker itself untouched. To also purge packages and delete Grafana/Prometheus configuration, dashboards, alert history, and metrics, answer `y` to the purge prompt and type `yes` when asked to confirm.

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
