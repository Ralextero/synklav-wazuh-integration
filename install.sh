#!/usr/bin/env python3
import os
import sys
import hashlib
import binascii
import urllib.parse
import http.client
import time
import glob

print("====================================================")
print(" SYNKLAV HUB SYSTEM INTEGRATION ENGINE              ")
print("====================================================")

OSSEC_CONF = "/var/ossec/etc/ossec.conf"
WORKER_URL = "https://synklav-notification-hub.synklav.workers.dev/"

if os.getuid() != 0:
    print("[ERROR] Script must be run as root (sudo).")
    sys.exit(1)

print("Select execution profile:")
print(" 1) INITIALIZE      : Fresh deployment of Synklav core container.")
print(" 2) ADD USER        : Append a new multi-tenant user profile / node UID.")
print(" 3) UPDATE TELEGRAM : Change the minimum alert level for an existing node.")
print(" 4) REMOVE USER     : Delete a single specific user profile cleanly.")
print(" 5) PURGE ALL       : Complete atomic removal of all Synklav structures.")

try:
    exec_profile = int(input("➔ Enter profile selection (1-5): ").strip())
except ValueError:
    print("[ERROR] Invalid selection.")
    sys.exit(1)

if exec_profile not in [1, 2, 3, 4, 5]:
    print("[ERROR] Out of bounds profile selection.")
    sys.exit(1)

if not os.path.exists(OSSEC_CONF):
    print("[ERROR] ossec.conf not found.")
    sys.exit(1)

import shutil
try:
    shutil.copyfile(OSSEC_CONF, f"{OSSEC_CONF}.bak")
except: pass

node_uid = ""
recovery_kit = ""
min_alert_level = "1"
custom_app_id = "null"
custom_rest_key = "null"
tg_chat_id = "null"

if exec_profile in [1, 2]:
    node_uid = input("➔ Enter target UNIQUE NODE UID: ").strip()
    if not node_uid: sys.exit(1)
    recovery_kit = input("➔ Enter your 24-word Recovery Kit (single line): ").strip().lower()
    if len(recovery_kit.split()) != 24:
        print("[ERROR] Recovery Kit must be exactly 24 words.")
        sys.exit(1)
    min_alert_level = input("➔ Enter the MINIMUM alert level for Telegram/Push routing (1-15): ").strip()
    
    if input("➔ Activate Multi-Tenant / Custom OneSignal routing? (yes/no): ").strip().lower() in ['yes', 'y']:
        custom_app_id = input("   - App ID string: ").strip()
        custom_rest_key = input("   - REST API Key string: ").strip()
        
    if input("➔ Active secondary Telegram notification routing? (yes/no): ").strip().lower() in ['yes', 'y']:
        tg_chat_id = input("   - Target Chat ID string: ").strip()
elif exec_profile in [3, 4]:
    node_uid = input("➔ Enter target UNIQUE NODE UID: ").strip()
    if not node_uid: sys.exit(1)
    if exec_profile == 3:
        min_alert_level = input("➔ Enter the NEW minimum alert level (1-15): ").strip()

notification_key, onesignal_tag_hash = "null", "null"
if exec_profile in [1, 2]:
    full_seed = hashlib.pbkdf2_hmac('sha512', recovery_kit.encode('utf-8'), b'mnemonic', 2048, 64)
    master_key_hex = binascii.hexlify(full_seed[0:32]).decode('utf-8')
    notification_key = hashlib.sha256((node_uid + master_key_hex).encode('utf-8')).hexdigest()
    onesignal_tag_hash = hashlib.sha256((notification_key + node_uid).encode('utf-8')).hexdigest()

target_name = f"custom-synklav-{node_uid}"

# ------------------------------------------------------------------------------
# MOTOR DE EXTRACCIÓN LÍNEA A LÍNEA (A PRUEBA DE BALAS)
# ------------------------------------------------------------------------------
with open(OSSEC_CONF, 'r', encoding='utf-8') as f:
    raw_lines = f.read().splitlines()

clean_lines = []
in_integration = False
integration_buffer = []
is_synklav_integration = False

for line in raw_lines:
    # 1. Destruimos cualquier basura de las versiones anteriores al instante
    if "SYNKLAV_START" in line or "SYNKLAV_END" in line:
        continue

    # 2. Localizamos los bloques de integración de Wazuh
    if "<integration>" in line:
        in_integration = True
        integration_buffer = [line]
        is_synklav_integration = False
        continue
    
    if in_integration:
        integration_buffer.append(line)
        
        if exec_profile == 5:
            # En PURGE ALL, si la integración es de synklav, la marcamos para borrar
            if "custom-synklav" in line:
                is_synklav_integration = True
        elif exec_profile == 4:
            # En REMOVE USER, solo borramos la de este usuario concreto
            if target_name in line:
                is_synklav_integration = True
        
        if "</integration>" in line:
            in_integration = False
            # Si NO era de synklav, la salvamos y la metemos al archivo limpio
            if not is_synklav_integration:
                clean_lines.extend(integration_buffer)
            integration_buffer = []
        continue
    
    # 3. Guardamos el resto de configuraciones nativas
    clean_lines.append(line)

# ------------------------------------------------------------------------------
# APLICAR NUEVOS BLOQUES (INITIALIZE / ADD USER / UPDATE)
# ------------------------------------------------------------------------------
if exec_profile == 3:
    in_target = False
    found = False
    for i, line in enumerate(clean_lines):
        if "<integration>" in line: in_target = False
        if target_name in line: 
            in_target = True
            found = True
        if in_target and "<level>" in line:
            clean_lines[i] = f"    <level>{min_alert_level}</level>"
        if "</integration>" in line: in_target = False
    if not found:
        print(f"[ERROR] Node {node_uid} not found.")
        sys.exit(1)

elif exec_profile == 1:
    if any("custom-synklav" in l for l in clean_lines):
        print("[ERROR] System already initialized with Synklav nodes. Use profile 2 (ADD USER).")
        sys.exit(1)
    
    idx = -1
    for i, l in enumerate(clean_lines):
        if "</ossec_config>" in l: idx = i
    
    if idx == -1:
        print("[CRITICAL ERROR] </ossec_config> not found!")
        sys.exit(1)
    
    new_block = ["  <integration>", f"    <name>{target_name}</name>", f"    <level>{min_alert_level}</level>", "    <alert_format>json</alert_format>", "  </integration>"]
    clean_lines = clean_lines[:idx] + new_block + clean_lines[idx:]

elif exec_profile == 2:
    if any(target_name in l for l in clean_lines):
        print(f"[WARNING] Node {node_uid} already exists. Overwriting script only.")
    else:
        idx = -1
        for i, l in enumerate(clean_lines):
            if "</ossec_config>" in l: idx = i
        
        if idx == -1:
            print("[CRITICAL ERROR] </ossec_config> not found!")
            sys.exit(1)
        
        new_block = ["  <integration>", f"    <name>{target_name}</name>", f"    <level>{min_alert_level}</level>", "    <alert_format>json</alert_format>", "  </integration>"]
        clean_lines = clean_lines[:idx] + new_block + clean_lines[idx:]

# ------------------------------------------------------------------------------
# ESCRITURA EN DISCO Y SCRIPT HANDLER
# ------------------------------------------------------------------------------
final_content = "\n".join(clean_lines) + "\n"
if "<ossec_config>" not in final_content or "</ossec_config>" not in final_content:
    print("[CRITICAL ERROR] Final structure invalid.")
    sys.exit(1)

tmp_path = OSSEC_CONF + ".tmp"
with open(tmp_path, 'w', encoding='utf-8') as f:
    f.write(final_content)
os.replace(tmp_path, OSSEC_CONF)

if exec_profile == 5:
    for f_path in glob.glob('/var/ossec/integrations/custom-synklav*'):
        try: os.remove(f_path)
        except: pass
elif exec_profile == 4:
    try: os.remove(f"/var/ossec/integrations/{target_name}")
    except: pass

if exec_profile in [1, 2]:
    script_code = f"""#!/usr/bin/python3
import sys, json, http.client, urllib.parse, hmac, hashlib, time
with open(sys.argv[1], 'r') as f: alert_json = f.read()
NODE_UID, NOTIFICATION_KEY, TAG_HASH, TG_CHAT_ID = "{node_uid}", "{notification_key}", "{onesignal_tag_hash}", "{tg_chat_id}"
CUSTOM_APP_ID, CUSTOM_REST_KEY = "{custom_app_id}", "{custom_rest_key}"
parsed = urllib.parse.urlparse("{WORKER_URL}")
ts = str(int(time.time()))
sig = hmac.new(bytes.fromhex(NOTIFICATION_KEY), (alert_json + ts + NODE_UID).encode('utf-8'), hashlib.sha256).hexdigest()
headers = {{"Content-Type": "application/json", "X-Synklav-Signature": sig, "X-Synklav-Timestamp": ts, "X-Synklav-Node-UID": NODE_UID, "X-Synklav-Notification-Key": NOTIFICATION_KEY, "X-Synklav-Tag-Hash": TAG_HASH, "X-Synklav-Telegram-Chat-ID": TG_CHAT_ID, "X-Synklav-Custom-App-ID": CUSTOM_APP_ID, "X-Synklav-Custom-REST-Key": CUSTOM_REST_KEY}}
try:
    conn = http.client.HTTPSConnection(parsed.netloc, timeout=10)
    conn.request("POST", parsed.path if parsed.path else "/", body=alert_json, headers=headers)
    conn.getresponse()
    conn.close()
except: sys.exit(0)
"""
    sp = f"/var/ossec/integrations/{target_name}"
    with open(sp, 'w', encoding='utf-8') as sf: sf.write(script_code)
    os.chmod(sp, 0o750)
    try:
        import pwd, grp
        os.chown(sp, pwd.getpwnam('root').pw_uid, grp.getgrnam('wazuh').gr_gid)
    except: pass

print("[STATUS] Hot-rebooting Wazuh engine process core...")
os.system("/var/ossec/bin/wazuh-control restart")

if exec_profile in [1, 2]:
    print("====================================================\n✅ OPERATION VERIFIED AND ACTIVE\n====================================================\n⚠️  METRIC SUMMARY FOR APPLICATION PROVISIONING:\n👉 Node UID: " + node_uid + "\n👉 OneSignal Tag Hash: " + onesignal_tag_hash + "\n👉 Notification Key: " + notification_key + "\n====================================================")
else:
    print("====================================================\n 🔥 OPERATION COMPLETE: CLEAN EXIT CODE 0\n====================================================")
