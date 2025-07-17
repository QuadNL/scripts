# PBS MQTT Backup Status Installer

This script automates the setup of MQTT-based backup status reporting from a **Proxmox Backup Server (PBS)** to **Home Assistant** using MQTT. It installs required packages, generates an API token, configures a reporting script, and schedules it via cron.

## Features
- Installs required dependencies (`jq`, `mosquitto-clients`)
- Creates or replaces a PBS API token
- Generates a reporting script that:
  - Queries PBS for backup job status
  - Publishes status and metadata to MQTT topics
  - Supports Home Assistant MQTT discovery
- Configurable via interactive prompts
- Optional logging and cron scheduling

## Requirements

Before running this installer, make sure the following components are available and properly configured:

- **Proxmox Backup Server (PBS)**  
  - Version: **8.4.1** (tested and supported)
  - Installed as either an LXC container or a virtual machine

- **MQTT Broker**  
  - A running MQTT broker (e.g., Mosquitto)
  - Accessible from the PBS host
  - MQTT credentials (host, port, username, password)

- **Linux Shell Access**  
  - Root or sudo privileges on the PBS host

- **Internet Access**  
  - Required to install missing packages and fetch updates

## Installation

In the Proxmox Backup Server shell run:

bash <(curl -s https://raw.githubusercontent.com/QuadNL/scripts/main/Proxmox%20Backup%20Server%20to%20MQTT/install_pbs_mqtt.sh)

Run the script as root:

```bash
sudo bash install_pbs_mqtt.sh

During installation you'll be asked for or confirm to:
  - User used for the Proxmox Backup Server connection
  - IP Address of MQTT broker
  - MQTT Port (default 1883)
  - MQTT User and Password
  - Stale Hours (Stale means it's been longer than the defined time between backups since the last one occured)
  - Preferred interval
  - Logging (basic)
  - Run after installation
