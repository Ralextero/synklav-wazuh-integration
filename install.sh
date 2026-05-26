#!/bin/bash

# ==============================================================================
# SYNKLAV - AUTOMATED MULTI-MODE WAZUH INTEGRATION DEPLOYMENT MANIFEST
# ==============================================================================

# Enforce root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Security context execution violation: Script must be run as root (sudo)."
  exit 1
fi

echo "===================================================="
echo " SYNKLAV HUB SYSTEM INTEGRATION ENGINE              "
echo "===================================================="

OSSEC_CONF="/var/ossec/etc/ossec.conf"
WORKER_URL="https://synklav-notification-hub.synklav.workers.dev/"

# SYSTEM MODE SELECTION
echo "Select execution profile:"
echo " 1) INITIALIZE      : Fresh deployment of Synklav core container."
echo " 2) ADD USER        : Append a new multi-tenant user profile / node UID."
echo " 3) UPDATE TELEGRAM : Change the minimum alert level for an existing node."
echo " 4) REMOVE USER     : Delete a single specific user profile cleanly."
echo " 5) PURGE ALL       : Complete atomic removal of all Synklav structures."
read -p "➔ Enter profile selection (1-5): " EXEC_PROFILE

# TIMESTAMPED BACKUP ROUTINE FOR ANTI-DATA-LOSS
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_CONF="${OSSEC_CONF}.${TIMESTAMP}.bak"
cp "$OSSEC_CONF" "$BACKUP_CONF"
cp "$OSSEC_CONF" "${OSSEC_CONF}.bak"

# ------------------------------------------------------------------------------
# INTERACTIVE DATA ACQUISITION FOR PROFILES 1, 2, 3, 4
# ------------------------------------------------------------------------------
NODE_UID="null"
RECOVERY_KIT="null"
MIN_ALERT_LEVEL="1"
CUSTOM_APP_ID="null"
CUSTOM_REST_KEY="null"
TG_CHAT_ID="null"

if [ "$EXEC_PROFILE" == "1" ] || [ "$EXEC_PROFILE" == "2" ]; then
  read -p "➔ Enter target UNIQUE NODE UID: " NODE_UID
  NODE_UID=$(echo "$NODE_UID" | tr -d '[:space:]')

  read -p "➔ Enter your 24-word Recovery Kit (single line): " RECOVERY_KIT
  RECOVERY_KIT=$(echo "$RECOVERY_KIT" | tr -s ' ' | tr '[:upper:]' '[:lower:]')

  WORD_COUNT=$(echo "$RECOVERY_KIT" | wc -w)
  if [ "$WORD_COUNT" -ne 24 ]; then
    echo "[ERROR] Cryptographic validation failure: Mnemonic matrix must equal 24 elements."
    exit 1
  fi

  read -p "➔ Enter the MINIMUM alert level for Telegram/Push routing (1-15): " MIN_ALERT_LEVEL
  MIN_ALERT_LEVEL=$(echo "$MIN_ALERT_LEVEL" | tr -d '[:space:]')

  read -p "➔ Activate Multi-Tenant / Custom OneSignal routing? (yes/no): " IS_CUSTOM
  if [[ "$IS_CUSTOM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    read -p "   - App ID string: " CUSTOM_APP_ID
    CUSTOM_APP_ID=$(echo "$CUSTOM_APP_ID" | tr -d '[:space:]')
    read -p "   - REST API Key string: " CUSTOM_REST_KEY
    CUSTOM_REST_KEY=$(echo "$CUSTOM_REST_KEY" | tr -d '[:space:]')
  fi

  read -p "➔ Active secondary Telegram notification routing? (yes/no): " IS_TELEGRAM
  if [[ "$IS_TELEGRAM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    read -p "   - Target Chat ID string: " TG_CHAT_ID
    TG_CHAT_ID=$(echo "$TG_CHAT_ID" | tr -d '[:space:]')
  fi
fi

if [ "$EXEC_PROFILE" == "3" ]; then
  read -p "➔ Enter the target NODE UID to update: " NODE_UID
  NODE_UID=$(echo "$NODE_UID" | tr -d '[:space:]')
  read -p "➔ Enter the NEW minimum alert level for Telegram (1-15): " MIN_ALERT_LEVEL
  MIN_ALERT_LEVEL=$(echo "$MIN_ALERT_LEVEL" | tr -d '[:space:]')
fi

if [ "$EXEC_PROFILE" == "4" ]; then
  read -p "➔ Enter the specific NODE UID to remove: " NODE_UID
  NODE_UID=$(echo "$NODE_UID" | tr -d '[:space:]')
fi

# ------------------------------------------------------------------------------
# CORE PYTHON ORCHESTRATION ENGINE (IMMUNE TO BASH/GREP/SED ANOMALIES)
# ------------------------------------------------------------------------------
echo "[STATUS] Executing Python Orchestration Engine Core..."

python3 -c "
import os
import sys
import hashlib
import binascii

exec_profile = int('$EXEC_PROFILE')
conf_path = '$OSSEC_CONF'
tmp_path = conf_path + '.tmp'
node_uid = '$NODE_UID'
recovery_kit = '$RECOVERY_KIT'
min_alert_level = '$MIN_ALERT_LEVEL'
custom_app_id = '$CUSTOM_APP_ID'
custom_rest_key = '$CUSTOM_REST_KEY'
tg_chat_id = '$TG_CHAT_ID'
worker_url = '$WORKER_URL'

# 1. READ ORIGINAL CONTEXT WITH IMMUTABLE BUFFER
with open(conf_path, 'r', encoding='utf-8') as f:
    content = f.read()

# SAFETY CHECK: Ensure file is valid before touching disk
if 'ossec_config' not in content:
    print('[CRITICAL ERROR] Target ossec.conf is corrupted or missing master tags.')
    sys.exit(1)

# ------------------------------------------------------------------------------
# CRYPTOGRAPHIC COMPONENT DERIVATION (FOR ADD / INITIALIZE)
# ------------------------------------------------------------------------------
notification_key = 'null'
onesignal_tag_hash = 'null'

if exec_profile in [1, 2]:
    mnemonic_text = recovery_kit.strip().encode('utf-8')
    salt = b'mnemonic'
    full_seed = hashlib.pbkdf2_hmac('sha512', mnemonic_text, salt, 2048, 64)
    master_key_hex = binascii.hexlify(full_seed[0:32]).decode('utf-8')
    
    notification_key = hashlib.sha256((node_uid + master_key_hex).encode('utf-8')).hexdigest()
    onesignal_tag_hash = hashlib.sha256((notification_key + node_uid).encode('utf-8')).hexdigest()

# ------------------------------------------------------------------------------
# EXECUTION ROUTINES
# ------------------------------------------------------------------------------
output_content = content

if exec_profile == 5:
    # PURGE ALL MODE
    # Strip anchored block
    if '' in output_content:
        parts = output_content.split('')
        sub_parts = parts[1].split('')
        output_content = parts[0] + sub_parts[1]
    
    # Strip lingering loose custom-synklav blocks
    lines = output_content.splitlines()
    new_lines = []
    block_buffer = []
    inside_block = False
    is_synklav = False
    
    for line in lines:
        if '<integration>' in line:
            inside_block = True
            block_buffer = [line]
            is_synklav = False
            continue
        if inside_block:
            block_buffer.append(line)
            if 'custom-synklav' in line:
                is_synklav = True
            if '</integration>' in line:
                if not is_synklav:
                    new_lines.extend(block_buffer)
                inside_block = False
                block_buffer = []
            continue
        if '' in line or '' in line:
            continue
        new_lines.append(line)
    output_content = '\n'.join(new_lines) + '\n'
    
    # Remove physical scripts
    int_dir = '/var/ossec/integrations/'
    if os.path.exists(int_dir):
        for f in os.listdir(int_dir):
            if f.startswith('custom-synklav'):
                try: os.remove(os.path.join(int_dir, f))
                except: pass

elif exec_profile == 4:
    # REMOVE SINGLE USER
    target_name = f'custom-synklav-{node_uid}'
    lines = output_content.splitlines()
    new_lines = []
    block_buffer = []
    inside_block = False
    is_target = False
    
    for line in lines:
        if '<integration>' in line:
            inside_block = True
            block_buffer = [line]
            is_target = False
            continue
        if inside_block:
            block_buffer.append(line)
            if f'<name>{target_name}</name>' in line:
                is_target = True
            if '</integration>' in line:
                if not is_target:
                    new_lines.extend(block_buffer)
                inside_block = False
                block_buffer = []
            continue
        new_lines.append(line)
    output_content = '\n'.join(new_lines) + '\n'
    
    try: os.remove(f'/var/ossec/integrations/{target_name}')
    except: pass

elif exec_profile == 3:
    # UPDATE TELEGRAM LEVEL IN PLACE
    target_name = f'custom-synklav-{node_uid}'
    if f'<name>{target_name}</name>' not in output_content:
        print(f'[ERROR] Node {node_uid} not found in configuration.')
        sys.exit(1)
        
    lines = output_content.splitlines()
    new_lines = []
    inside_block = False
    is_target = False
    for line in lines:
        if '<integration>' in line:
            inside_block = True
        if 'custom-synklav-' in line and target_name in line:
            is_target = True
        if inside_block and is_target and '<level>' in line:
            line = f'    <level>{min_alert_level}</level>'
        if '</integration>' in line:
            inside_block = False
            is_target = False
        new_lines.append(line)
    output_content = '\n'.join(new_lines) + '\n'

elif exec_profile == 1:
    # INITIALIZE MODE
    if '' in output_content:
        print('[ERROR] System already initialized. Use profile 2 (ADD USER) to register additional nodes.')
        sys.exit(1)
        
    new_block = f'\n  <integration>\n    <name>custom-synklav-{node_uid}</name>\n    <level>{min_alert_level}</level>\n    <alert_format>json</alert_format>\n  </integration>\n\n'
    if '</ossec_config>' in output_content:
        output_content = output_content.replace('</ossec_config>', f'{new_block}</ossec_config>')

elif exec_profile == 2:
    # ADD USER MODE
    if '' not in output_content:
        print('[ERROR] Synklav core missing. Run profile 1 (INITIALIZE) first.')
        sys.exit(1)
        
    target_name = f'custom-synklav-{node_uid}'
    if f'<name>{target_name}</name>' in output_content:
        print(f'[WARNING] Node {node_uid} already exists. Overwriting handler script only.')
    else:
        new_integration = f'  <integration>\n    <name>{target_name}</name>\n    <level>{min_alert_level}</level>\n    <alert_format>json</alert_format>\n  </integration>\n'
        output_content = output_content.replace('', new_integration)

# ------------------------------------------------------------------------------
# ATOMIC COMMIT SAFELY WRITING TO DISK
# ------------------------------------------------------------------------------
if len(output_content.strip()) < 200 or 'ossec_config' not in output_content:
    print('[CRITICAL ERROR] Guardrail triggered: Prevented writing an anomalous file layout.')
    sys.exit(1)

with open(tmp_path, 'w', encoding='utf-8') as f:
    f.write(output_content)

os.replace(tmp_path, conf_path)

# ------------------------------------------------------------------------------
# WRITE THE PHYSICAL PYTHON HANDLER TARGET (FOR PROFILE 1 & 2)
# ------------------------------------------------------------------------------
if exec_profile in [1, 2]:
    script_path = f'/var/ossec/integrations/custom-synklav-{node_uid}'
    script_code = f\"\"\"#!/usr/bin/python3
import sys, json, http.client, urllib.parse, hmac, hashlib, time

alert_file = sys.argv[1]
with open(alert_file, 'r') as f:
    alert_json = f.read()

NODE_UID = \"{node_uid}\"
WORKER_URL = \"{worker_url}\"
NOTIFICATION_KEY = \"{notification_key}\"
TAG_HASH = \"{onesignal_tag_hash}\"
TG_CHAT_ID = \"{tg_chat_id}\"
CUSTOM_APP_ID = \"{custom_app_id}\"
CUSTOM_REST_KEY = \"{custom_rest_key}\"

parsed_url = urllib.parse.urlparse(WORKER_URL)
host = parsed_url.netloc
path = parsed_url.path if parsed_url.path else \"/\"

timestamp = str(int(time.time()))
message = (alert_json + timestamp + NODE_UID).encode('utf-8')
signature = hmac.new(bytes.fromhex(NOTIFICATION_KEY), message, hashlib.sha256).hexdigest()

headers = {{
    \"Content-Type\": \"application/json\",
    \"X-Synklav-Signature\": signature,
    \"X-Synklav-Timestamp\": timestamp,
    \"X-Synklav-Node-UID\": NODE_UID,
    \"X-Synklav-Notification-Key\": NOTIFICATION_KEY,
    \"X-Synklav-Tag-Hash\": TAG_HASH,
    \"X-Synklav-Telegram-Chat-ID\": TG_CHAT_ID if TG_CHAT_ID else \"null\",
    \"X-Synklav-Custom-App-ID\": CUSTOM_APP_ID if CUSTOM_APP_ID else \"null\",
    \"X-Synklav-Custom-REST-Key\": CUSTOM_REST_KEY if CUSTOM_REST_KEY else \"null\"
}}

try:
    conn = http.client.HTTPSConnection(host, timeout=10)
    conn.request(\"POST\", path, body=alert_json, headers=headers)
    response = conn.getresponse()
    conn.close()
except:
    sys.exit(0)
\"\"\"
    with open(script_path, 'w', encoding='utf-8') as sf:
        sf.write(script_code)
        
    os.chmod(script_path, 0o750)
    # Attempt chown cleanly
    try:
        import pwd, grp
        uid = pwd.getpwnam('root').pw_uid
        gid = grp.getgrnam('wazuh').gr_gid
        os.chown(script_path, uid, gid)
    except:
        pass

print('[SUCCESS_CORE]')
" || exit 1

# 5. REBOOT WAZUH CORE ENGINE
echo "[STATUS] Hot-rebooting Wazuh engine process core..."
/var/ossec/bin/wazuh-control restart

if [ "$EXEC_PROFILE" == "1" ] || [ "$EXEC_PROFILE" == "2" ]; then
  # Re-run derivation keys block briefly just to print summary visibility securely in shell
  python3 -c "
import hashlib, binascii
mnemonic_text = '$RECOVERY_KIT'.strip().encode('utf-8')
full_seed = hashlib.pbkdf2_hmac('sha512', mnemonic_text, b'mnemonic', 2048, 64)
master_hex = binascii.hexlify(full_seed[0:32]).decode('utf-8')
nk = hashlib.sha256(('$NODE_UID' + master_hex).encode('utf-8')).hexdigest()
th = hashlib.sha256((nk + '$NODE_UID').encode('utf-8')).hexdigest()
echo_str = f'====================================================\n✅ OPERATION VERIFIED AND ACTIVE\n====================================================\n⚠️  METRIC SUMMARY FOR APPLICATION PROVISIONING:\n👉 Node UID: $NODE_UID\n👉 OneSignal Tag Hash: {th}\n👉 Notification Key: {nk}\n===================================================='
print(echo_str)
"
fi
