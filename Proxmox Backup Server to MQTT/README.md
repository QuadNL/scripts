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
  - Version: **3.4.2** (tested and supported)
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

In the Proxmox Backup Server shell run the script as root:

```bash
bash <(curl -s https://raw.githubusercontent.com/QuadNL/scripts/main/Proxmox%20Backup%20Server%20to%20MQTT/install_pbs_mqtt.sh)
```

During installation you'll be asked for or confirm to:
  - User used for the Proxmox Backup Server connection
  - IP Address of MQTT broker
  - MQTT Port (default 1883)
  - MQTT User and Password
  - Device Name for MQTT e.g. PBS. (this will be used for Device name and sensor: sensor.{devicename}_backup_{ct/vm ID}
  - Stale Hours (Stale means it's been longer than the defined time between backups since the last one occured)
  - Preferred interval
  - Logging (basic)
  - Run after installation

## After installation
After installation you'll see incoming MQTT packets on your MQTT broker and in Home Assistant there is a device created under MQTT: Proxmox Backup Server.
Each entity contains the following information:

<img width="1256" height="227" alt="image" src="https://github.com/user-attachments/assets/e1c3e75d-8624-4ed6-b8a3-e20c1cfc2a8b" />

Which can be used as sensors in your dashboards or automations:
<img width="797" height="357" alt="image" src="https://github.com/user-attachments/assets/fd50484e-c094-490d-93bb-996869208ba1" />


## Issues
If you encounter any issues, please open an issue in the GitHub repository. When reporting a bug, include relevant logs or command output if possible.

## Contribution
Contributions are welcome! Feel free to fork the repository and submit a pull request with improvements, bug fixes, or new features. Please keep changes modular and well-documented.

## License

# Legal Disclaimer
Use this software at your own risk. This software comes with no warranty, either express or implied.
I assume no liability for the use or misuse of this software or its derivatives.
This software is offered "as-is". I will not install, remove, operate or support this software at your request.
If you are unsure of how this software will interact with your system, do not use it.
