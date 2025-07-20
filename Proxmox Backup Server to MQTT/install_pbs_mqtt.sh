#!/bin/bash

echo "=== PBS MQTT Backup Status Installer ==="
# --- Required packages setup ---
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

# --- Script and MQTT configuration ---
read -p "IP Address of MQTT broker: " MQTT_HOST
read -p "MQTT Port (default 1883): " MQTT_PORT
MQTT_PORT=${MQTT_PORT:-1883}
read -p "MQTT User: " MQTT_USER
read -rp "MQTT Password: " MQTT_PASS
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

# --- Saving script ---
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

declare -A LAST_KNOWN_STATUS

mqtt_publish() {
  local topic="\$1"
  local payload="\$2"
  mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$topic" -m "\$payload" -r
}

mqtt_publish "\$MQTT_BASE_TOPIC/availability" "online"

DATASTORE_RAW_JSON=\$(proxmox-backup-manager datastore list --output-format json)

ALL_SNAPSHOTS_JSON="[]"
for DATASTORE in \$(echo "\$DATASTORE_RAW_JSON" | jq -r '.[].name'); do
  export PBS_REPOSITORY="\$TOKEN_ID@localhost:\$DATASTORE"
  export PBS_PASSWORD="\$TOKEN_SECRET"

  SNAPSHOTS_JSON=\$(proxmox-backup-client snapshot list --output-format json | \
    jq --arg ds "\$DATASTORE" '[.[] | . + {datastore: \$ds}]')

  ALL_SNAPSHOTS_JSON=\$(jq -s 'add' <(echo "\$ALL_SNAPSHOTS_JSON") <(echo "\$SNAPSHOTS_JSON"))
done

RAW_TASKS=\$(proxmox-backup-manager task list --all --limit 1000 --output-format json | jq '[.[] | select(.worker_type == "backup")]')

mapfile -t LATEST_SNAPSHOTS < <(echo "\$ALL_SNAPSHOTS_JSON" | jq -c '
  group_by(."backup-id")[] | max_by(."backup-time")
')

for SNAPSHOT in "\${LATEST_SNAPSHOTS[@]}"; do
  ID=\$(echo "\$SNAPSHOT" | jq -r '."backup-id"')
  TYPE=\$(echo "\$SNAPSHOT" | jq -r '."backup-type"')
  COMMENT=\$(echo "\$SNAPSHOT" | jq -r '(.comment // "none")')
  BACKUP_TIME=\$(echo "\$SNAPSHOT" | jq -r '."backup-time"')
  SIZE_BYTES=\$(echo "\$SNAPSHOT" | jq -r '.size // 0')
  DATASTORE=\$(echo "\$SNAPSHOT" | jq -r '.datastore')

  FRIENDLY_ID="\${TYPE}\${ID}"
  FRIENDLY_NAME="\${FRIENDLY_ID} (\${COMMENT})"
  FRIENDLY_TYPE=\$(case "\$TYPE" in
    "ct") echo "LXC" ;;
    "vm") echo "VM" ;;
    *) echo "\$TYPE" ;;
  esac)

  if [[ "\$SIZE_BYTES" =~ ^[0-9]+\$ && "\$SIZE_BYTES" -gt 0 ]]; then
    SIZE_GIB=\$(awk "BEGIN { printf \"%.2f\", \$SIZE_BYTES / 1024 / 1024 / 1024 }" | sed 's/\./,/')
    SIZE_FORMATTED="\${SIZE_GIB} GiB"
  else
    SIZE_FORMATTED="n/a"
  fi

  NOW=\$(date +%s)
  AGE_SEC=\$((NOW - BACKUP_TIME))
  HOURS=\$((AGE_SEC / 3600))
  MINUTES=\$(((AGE_SEC % 3600) / 60))
  SECONDS=\$((AGE_SEC % 60))
  HUMAN_AGE=\$(printf "%02d:%02d:%02d" "\$HOURS" "\$MINUTES" "\$SECONDS")
  STALE=false
  [[ \$AGE_SEC -gt \$((STALE_HOURS * 3600)) ]] && STALE=true

  STATUS=\$(echo "\$RAW_TASKS" | jq -r \
    --arg type "\$TYPE" \
    --arg id "\$ID" \
    --arg datastore "\$DATASTORE" \
    '
    map(select(.worker_type == "backup"))
    | map(select(.worker_id | startswith(\$datastore + ":" + \$type + "/" + \$id)))
    | sort_by(.endtime)
    | reverse
    | .[0].status // "unknown"
    ')

  if [[ "\$STATUS" != "unknown" ]]; then
    LAST_KNOWN_STATUS[\$ID]="\$STATUS"
  fi

  STATE_TOPIC="\$MQTT_BASE_TOPIC/\${FRIENDLY_ID}/status"
  ATTR_TOPIC="\$MQTT_BASE_TOPIC/\${FRIENDLY_ID}/attributes"
  DISCOVERY_TOPIC="homeassistant/sensor/${DEVICENAME}_backup_\${FRIENDLY_ID}/config"

  DISCOVERY_PAYLOAD=\$(jq -n \
    --arg name "\$FRIENDLY_NAME" \
    --arg object_id "${DEVICENAME}_backup_\${FRIENDLY_ID}" \
    --arg unique_id "${DEVICENAME}_backup_\${FRIENDLY_ID}_status" \
    --arg state_topic "\$STATE_TOPIC" \
    --arg attr_topic "\$ATTR_TOPIC" \
    --arg avail_topic "\$MQTT_BASE_TOPIC/availability" \
    --arg icon "mdi:backup-restore" \
    --arg device_class "enum" \
    --argjson device "\$HA_DEVICE" \
    '{
      name: \$name,
      object_id: \$object_id,
      unique_id: \$unique_id,
      state_topic: \$state_topic,
      json_attributes_topic: \$attr_topic,
      availability_topic: \$avail_topic,
      icon: \$icon,
      device_class: \$device_class,
      device: \$device
    }')

  ATTR_PAYLOAD=\$(jq -n \
    --arg status "\$STATUS" \
    --arg ID "\$FRIENDLY_ID" \
    --arg comment "\$COMMENT" \
    --arg finished "\$(date -d "@\$BACKUP_TIME" +"%Y-%m-%d at %H:%M:%S")" \
    --arg size "\$SIZE_FORMATTED" \
    --arg age "\$HUMAN_AGE" \
    --argjson stale "\$STALE" \
    --arg type "\$FRIENDLY_TYPE" \
    --arg datastore "\$DATASTORE" \
    '{
      status: \$status,
      type: \$type,
      ID: \$ID,
      comment: \$comment,
      "latest backup": \$finished,
      "backup size": \$size,
      "backup age": \$age,
      datastore : \$datastore,       
      stale: \$stale
    }')

  mqtt_publish "\$STATE_TOPIC" "\$STATUS"
  mqtt_publish "\$ATTR_TOPIC" "\$ATTR_PAYLOAD"
  mqtt_publish "\$DISCOVERY_TOPIC" "\$DISCOVERY_PAYLOAD"
done
EOF

# --- Set script as executable ---
chmod +x "$SCRIPT_PATH"

# --- Crontab setup ---
crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > /tmp/cron.tmp || true
rm --force /var/log/pbs_mqtt.log

CRON_CMD="$SCRIPT_PATH"
[ "$ENABLE_LOGGING" = "yes" ]  && CRON_CMD="$CRON_CMD >> /var/log/pbs_mqtt.log 2>&1"
echo "*/$CRON_INTERVAL * * * * $CRON_CMD" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp

# --- Certificate setup ---
echo "Configuring TLS fingerprint for localhost"
openssl s_client -connect localhost:8007 </dev/null 2>/dev/null | openssl x509 -outform PEM > /usr/local/share/ca-certificates/pbs.crt
update-ca-certificates

# --- Finishing tasks ---
echo "Script installed at $SCRIPT_PATH"
echo "Cronjob scheduled every $CRON_INTERVAL minutes"
[ "$ENABLE_LOGGING" = "yes" ] && echo "Logging enabled at /var/log/pbs_mqtt.log"

read -p "Run script now? (yes/no, default yes): " RUN_SCRIPT_NOW
RUN_SCRIPT_NOW=${RUN_SCRIPT_NOW,,}
RUN_SCRIPT_NOW=${RUN_SCRIPT_NOW:-yes}
[ "$RUN_SCRIPT_NOW" = "yes" ] && bash "$SCRIPT_PATH"
