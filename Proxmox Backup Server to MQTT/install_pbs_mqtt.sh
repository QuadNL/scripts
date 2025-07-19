#!/bin/bash

echo "=== PBS MQTT Backup Status Installer ==="
echo "Checking for required packages..."

REQUIRED_PACKAGES=("proxmox-backup-client" "jq" "mosquitto-clients")
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PACKAGES+=("$pkg")
  fi
done

if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
  echo "Installing missing packages: ${MISSING_PACKAGES[*]}"
  apt-get install -y "${MISSING_PACKAGES[@]}"
else
  echo "All required packages are already installed."
fi

# --- Token setup ---
read -p "User ID for API authentication (default root@pam): " USERID
USERID=${USERID:-root@pam}
TOKEN_NAME="mqtt-status"
TOKEN_SECRET_FILE="/root/.pbs_mqtt_token_secret"

# Check if token exists, delete if so
if proxmox-backup-manager user list-tokens "$USERID" | grep -q "$TOKEN_NAME"; then
  echo "API token '$TOKEN_NAME' already exists, deleting..."
  proxmox-backup-manager user delete-token "$USERID" "$TOKEN_NAME" || {
    echo "Error deleting token, aborting."
    exit 1
  }
fi

echo "Recreating API token '$TOKEN_NAME'..."
TOKEN_OUTPUT=$(proxmox-backup-manager user generate-token "$USERID" "$TOKEN_NAME")

# Remove leading "Result: " from output and extract the token value using jq
TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | sed '1s/^Result: //' | jq -r '.value')

if [ -z "$TOKEN_SECRET" ] || [ "$TOKEN_SECRET" = "null" ]; then
  echo "Error: unable to retrieve token secret."
  exit 1
fi

echo "$TOKEN_SECRET" > "$TOKEN_SECRET_FILE"
chmod 600 "$TOKEN_SECRET_FILE"
echo "API token secret saved to $TOKEN_SECRET_FILE"

TOKEN_ID=${USERID}!${TOKEN_NAME}
PBS_TOKEN_SECRET=$(cat "$TOKEN_SECRET_FILE")

echo "Setting ACL permissions for $USERID with role DatastoreAudit."
proxmox-backup-manager acl update /datastore DatastoreAudit --auth-id $TOKEN_ID

read -p "IP Address of MQTT broker: " MQTT_HOST
read -p "MQTT Port (default 1883): " MQTT_PORT
MQTT_PORT=${MQTT_PORT:-1883}
read -p "MQTT User: " MQTT_USER
read -p "MQTT Password: " MQTT_PASS
read -p "Device name (default pbs): " DEVICENAME
DEVICENAME=${DEVICENAME:-pbs}
read -p "Stale Hours (default 72): " STALE_HOURS
STALE_HOURS=${STALE_HOURS:-72}
read -p "Run script every X minutes (default 15): " CRON_INTERVAL
CRON_INTERVAL=${CRON_INTERVAL:-15}
read -p "Enable logging? (yes/no, default yes): " ENABLE_LOGGING
ENABLE_LOGGING=${ENABLE_LOGGING,,}
ENABLE_LOGGING=${ENABLE_LOGGING:-yes}

SCRIPT_PATH="/usr/local/bin/pbs_mqtt_backup_status.sh"

echo "Creating script at $SCRIPT_PATH..."

cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MQTT_HOST="$MQTT_HOST"
MQTT_PORT=$MQTT_PORT
MQTT_USER="$MQTT_USER"
MQTT_PASS="$MQTT_PASS"
MQTT_BASE_TOPIC="proxmox/$DEVICENAME/backup_status"
STALE_HOURS=$STALE_HOURS

TOKEN_ID=$TOKEN_ID
TOKEN_SECRET=$PBS_TOKEN_SECRET

HA_DEVICE='{"identifiers":["$DEVICENAME"],"name":"$DEVICENAME","manufacturer":"Proxmox","model":"Backup Server"}'

mqtt_publish() {
  local topic="\$1"
  local payload="\$2"
  mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$topic" -m "\$payload" -r
}

backup_json=\$(proxmox-backup-manager task list --all --limit 1000 --output-format json |
  jq '[.[] | select(.worker_type == "backup")] | sort_by(.starttime) | group_by(.worker_id) | map({client: .[-1].worker_id, backups: [.[-1]]})')

echo "\$backup_json" | jq -c '.[]' | while read -r client_entry; do
  client=\$(echo "\$client_entry" | jq -r '.client')
  clean_name=\$(echo "$client" | sed 's/^[^:]*://' | tr -d '/')
  safe_client_topic=\$(echo "\$clean_name" | sed 's#[/:]#_#g')

  clean_backups=\$(echo "\$client_entry" | jq -c '
    .backups | map(
      del(.user, .node, .worker_type)
      + {
        start_human: (if .starttime then (.starttime | tonumber | strftime("%Y-%m-%d %H:%M:%S")) else "" end),
        end_human: (if .endtime then (.endtime | tonumber | strftime("%Y-%m-%d %H:%M:%S")) else "" end)
      }
    )
  ')

# Retrieve latest comment via proxmox-backup-client with token authentication
comment=""
if [[ "\$clean_backups" != "null" && "\$clean_backups" != "" ]]; then
  last_worker_id=\$(echo "\$clean_backups" | jq -r '.[0].worker_id // empty')
  if [ -n "\$last_worker_id" ]; then
    export PBS_TOKENID=\$TOKEN_ID
    export PBS_PASSWORD=\$TOKEN_SECRET
    REPO="\${last_worker_id%%:*}"
    group="\${last_worker_id#*:}"
    snapshot_json=\$(proxmox-backup-client snapshot list \$group --repository \$PBS_TOKENID@localhost:\$REPO --output-format json)
    comment=\$(echo \$snapshot_json | jq '.[-1].comment' | tr -d '"')
  fi
fi


  mqtt_publish "homeassistant/binary_sensor/pbs_backup_\${safe_client_topic}/config" ""

  discovery_topic="homeassistant/sensor/pbs_backup_\${safe_client_topic}_status/config"
  state_topic="\$MQTT_BASE_TOPIC/\${safe_client_topic}/status"
  attributes_topic="\$MQTT_BASE_TOPIC/\${safe_client_topic}/attributes"

  discovery_payload=\$(jq -n     --arg name "\$clean_name"     --arg unique_id "pbs_backup_\${safe_client_topic}_status"     --arg state_topic "\$state_topic"     --arg json_attributes_topic "\$attributes_topic"     --arg availability_topic "\$MQTT_BASE_TOPIC/availability"     --arg icon "mdi:backup-restore"     --arg device_class "enum"     --argjson device "\$HA_DEVICE"     '{
      name: \$name,
      unique_id: \$unique_id,
      state_topic: \$state_topic,
      json_attributes_topic: \$json_attributes_topic,
      availability_topic: \$availability_topic,
      icon: \$icon,
      device_class: \$device_class,
      device: \$device
    }')

  mqtt_publish "\$discovery_topic" "\$discovery_payload"

  state=\$(echo "\$clean_backups" | jq -r '.[0].status // "unknown"')
  backup_age=\$(echo "\$clean_backups" | jq '.[0].endtime // 0')
  now=\$(date +%s)
  age_sec=\$((now - backup_age))
  max_age_sec=\$((STALE_HOURS * 3600))

  is_stale="false"
  if (( age_sec > max_age_sec )); then
    state="stale"
    is_stale="true"
  fi

  hours=\$(( age_sec / 3600 ))
  minutes=\$(( (age_sec % 3600) / 60 ))
  seconds=\$(( age_sec % 60 ))
  human_age=\$(printf "%02d:%02d:%02d" "\$hours" "\$minutes" "\$seconds")

  mqtt_publish "\$state_topic" "\$state"

  latest_backup=\$(echo "\$clean_backups" | jq --arg stale "\$is_stale" --arg age "\$human_age" --arg comment "\$comment" --arg ID "\$clean_name" '.[0] | {
    status,
    ID: \$ID,
    comment: \$comment,
    "Job started": (.start_human | sub(" "; " at ")),
    "Job finished": (.end_human | sub(" "; " at ")),
    "Job duration": (
      if (.endtime and .starttime) then
        ((.endtime - .starttime) | tostring + " seconds")
      else
        "unknown"
      end
    ),
    backup_age: \$age,
    stale: (\$stale == "true")
  }')
  

  latest_backup=\$(echo "\$latest_backup" | jq --arg stale "\$is_stale" --arg age "\$human_age" --arg comment "\$comment" '. + {
    stale: (\$stale == "true"),
    backup_age: \$age
  }')
  
  mqtt_publish "\$attributes_topic" "\$latest_backup"
done

mqtt_publish "\$MQTT_BASE_TOPIC/availability" "online"
EOF

chmod +x "$SCRIPT_PATH"

# Remove existing cron job and logs for this script
crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > /tmp/cron.tmp || true
rm --force /var/log/pbs_mqtt.log

# Add new cron job
CRON_CMD="$SCRIPT_PATH"
[ "$ENABLE_LOGGING" = "yes" ]  && CRON_CMD="$CRON_CMD >> /var/log/pbs_mqtt.log 2>&1"
echo "*/$CRON_INTERVAL * * * * $CRON_CMD" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp

echo "Script installed at $SCRIPT_PATH"
echo "Cronjob scheduled every $CRON_INTERVAL minutes"
[ "$ENABLE_LOGGING" = "yes" ] && echo "Logging enabled at /var/log/pbs_mqtt.log"

echo "Configuring TLS fingerprint for localhost"
openssl s_client -connect localhost:8007 </dev/null 2>/dev/null | openssl x509 -outform PEM > /usr/local/share/ca-certificates/pbs.crt
update-ca-certificates
read -p "Run script now? (yes/no, default yes): " RUN_SCRIPT_NOW
RUN_SCRIPT_NOW=${RUN_SCRIPT_NOW,,}
RUN_SCRIPT_NOW=${RUN_SCRIPT_NOW:-yes}
[ "$RUN_SCRIPT_NOW" = "yes" ] && bash "$SCRIPT_PATH"
