#!/usr/bin/env python3
import os
import sys
import hashlib
import urllib.parse
import time
import glob
import shutil
import re
import atexit
import argparse
from datetime import datetime

print("====================================================")
print(" SYNKLAV HUB SYSTEM INTEGRATION ENGINE (FCM) v1   ")
print("====================================================")

OSSEC_CONF = "/var/ossec/etc/ossec.conf"
WORKER_URL = "https://synklav-notification-hub.synklav.workers.dev/"
LOCK_FILE = "/tmp/synklav_installer.lock"

# ------------------------------------------------------------------------------
# SEGURIDAD DE ENTORNO Y PRIVILEGIOS
# ------------------------------------------------------------------------------
if os.getuid() != 0:
    print("[CRITICAL] Script must be run as root (sudo).")
    sys.exit(1)

if os.path.exists(LOCK_FILE):
    print("[CRITICAL] Another instance of the Synklav installer is currently running.")
    sys.exit(1)

try:
    with open(LOCK_FILE, 'w') as f: f.write(str(os.getpid()))
except IOError:
    print("[CRITICAL] Failed to acquire execution lock.")
    sys.exit(1)

def cleanup_lock():
    if os.path.exists(LOCK_FILE): os.remove(LOCK_FILE)
atexit.register(cleanup_lock)

if not os.path.exists(OSSEC_CONF):
    print(f"[CRITICAL] {OSSEC_CONF} not found. Ensure execution occurs directly on the Wazuh Manager.")
    sys.exit(1)

# ------------------------------------------------------------------------------
# PARSER DE ARGUMENTOS
# ------------------------------------------------------------------------------
parser = argparse.ArgumentParser(description="Synklav Integration Installer")
parser.add_argument('--profile', type=int, choices=[1,2,3,4,5], help="Profile selection (1:Init, 2:Add, 3:Update, 4:Remove, 5:Purge)")
parser.add_argument('--uid', type=str, help="Node UID")
parser.add_argument('--key', type=str, help="Notification Key string from Mobile App")
parser.add_argument('--tg-chat', type=str, default="null", help="Telegram Chat ID")
parser.add_argument('--tg-level', type=str, default="1", help="Telegram Min Alert Level")

args = parser.parse_args()

def validate_node_uid(uid):
    if not uid or not re.match(r'^[a-zA-Z0-9_-]+$', uid):
        print("[CRITICAL] Invalid Node UID. Only alphanumeric, hyphens and underscores allowed.")
        sys.exit(1)
    return uid

def validate_tg_level(level):
    if not level or not str(level).isdigit() or not (1 <= int(level) <= 15):
        print("[CRITICAL] Telegram Minimum Level must be an integer between 1 and 15.")
        sys.exit(1)
    return str(level)

exec_profile = args.profile
if not exec_profile:
    print("Select execution profile:")
    print(" 1) INITIALIZE      : Fresh deployment of Synklav core container.")
    print(" 2) ADD USER        : Append a new user profile / node UID.")
    print(" 3) UPDATE TELEGRAM : Change the minimum alert level for Telegram routing.")
    print(" 4) REMOVE USER     : Delete a single specific user profile cleanly.")
    print(" 5) PURGE ALL       : Complete atomic removal of all Synklav structures.")
    try:
        exec_profile = int(input("➔ Enter profile selection (1-5): ").strip())
    except ValueError:
        print("[CRITICAL] Invalid selection.")
        sys.exit(1)

node_uid = args.uid
notification_key = args.key
tg_chat_id = args.tg_chat
tg_min_level = args.tg_level

if exec_profile in [1, 2]:
    if not node_uid: node_uid = input("➔ Enter target UNIQUE NODE UID (from Synklav App): ").strip()
    node_uid = validate_node_uid(node_uid)

    if not notification_key: notification_key = input("➔ Enter NOTIFICATION KEY (from Synklav App): ").strip()
    if not notification_key:
        print("[CRITICAL] Notification Key is strictly required.")
        sys.exit(1)

    # 🟢 DERIVACIÓN AUTÓNOMA: El servidor calcula internamente el tag_hash para el enrutamiento FCM
    tag_hash = hashlib.sha256((notification_key + node_uid).encode('utf-8')).hexdigest()

    if args.tg_chat == "null":
        if input("➔ Active secondary Telegram routing? (yes/no): ").strip().lower() in ['yes', 'y']:
            tg_chat_id = input("   - Target Chat ID string: ").strip()
            tg_min_level = input("   - Enter MINIMUM alert level for Telegram (1-15): ").strip()
    tg_min_level = validate_tg_level(tg_min_level)

elif exec_profile in [3, 4]:
    if not node_uid: node_uid = input("➔ Enter target UNIQUE NODE UID: ").strip()
    node_uid = validate_node_uid(node_uid)
    if exec_profile == 3 and args.tg_level == "1":
        tg_min_level = validate_tg_level(input("➔ Enter the NEW minimum alert level for Telegram (1-15): ").strip())

target_name = f"custom-synklav-{node_uid}" if node_uid else "custom-synklav-ALL"

# ------------------------------------------------------------------------------
# COPIA DE SEGURIDAD RESPALDADA
# ------------------------------------------------------------------------------
ts = datetime.now().strftime("%Y%m%d%H%M%S")
backup_path = f"{OSSEC_CONF}.{ts}.bak"
try:
    shutil.copyfile(OSSEC_CONF, backup_path)
    print(f"[STATUS] OSSEC Backup secured at: {backup_path}")
except Exception as e:
    print(f"[CRITICAL] Aborting deployment. Failed to write configuration backup: {e}")
    sys.exit(1)

# ------------------------------------------------------------------------------
# FILTRADO Y PARSEO LINEAL DE INTEGRACIONES
# ------------------------------------------------------------------------------
with open(OSSEC_CONF, 'r', encoding='utf-8') as f:
    raw_lines = f.read().splitlines()

clean_lines = []
buffer = []
inside_integration = False
is_target = False

for line in raw_lines:
    if re.match(r'^\s*<integration>\s*$', line):
        inside_integration = True
        buffer = [line]
        is_target = False
        continue

    if inside_integration:
        buffer.append(line)
        if exec_profile == 5 and "custom-synklav" in line:
            is_target = True
        elif exec_profile in [1, 2, 4] and target_name in line:
            is_target = True

        if re.match(r'^\s*</integration>\s*$', line):
            inside_integration = False
            if not is_target:
                clean_lines.extend(buffer)
            buffer = []
        continue

    clean_lines.append(line)

# Inyección ascendente de seguridad (justo antes del cierre del nodo raíz)
if exec_profile in [1, 2]:
    idx = -1
    for i in range(len(clean_lines)-1, -1, -1):
        if re.match(r'^\s*</ossec_config>\s*$', clean_lines[i]):
            idx = i
            break
            
    if idx == -1:
        print("[CRITICAL] Malformed configuration file: </ossec_config> tag missing.")
        sys.exit(1)
        
    new_block = [
        "  <integration>", 
        f"    <name>{target_name}</name>", 
        "    <level>3</level>", 
        "    <alert_format>json</alert_format>", 
        "  </integration>"
    ]
    clean_lines = clean_lines[:idx] + new_block + clean_lines[idx:]

final_content = "\n".join(clean_lines) + "\n"
tmp_path = OSSEC_CONF + ".tmp"
with open(tmp_path, 'w', encoding='utf-8') as f: f.write(final_content)
os.replace(tmp_path, OSSEC_CONF)

# ------------------------------------------------------------------------------
# PURGA Y ESCRITURA DEL DISPARADOR PYTHON
# ------------------------------------------------------------------------------
deleted_scripts_backup = {}
if exec_profile in [4, 5]:
    files_to_delete = []
    if exec_profile == 5:
        for f_path in glob.glob('/var/ossec/integrations/custom-synklav-*'):
            if re.match(r'^/var/ossec/integrations/custom-synklav-[a-zA-Z0-9_-]+$', f_path):
                files_to_delete.append(f_path)
    elif exec_profile == 4:
        target_file = f"/var/ossec/integrations/{target_name}"
        if os.path.exists(target_file): files_to_delete.append(target_file)

    for f_path in files_to_delete:
        try:
            with open(f_path, 'rb') as f:
                deleted_scripts_backup[f_path] = f.read()
            os.remove(f_path)
        except Exception as e:
            pass

def safe_extract(pattern, text, default=None):
    match = re.search(pattern, text)
    return match.group(1) if match else default

if exec_profile in [1, 2, 3]:
    if exec_profile == 3:
        sp = f"/var/ossec/integrations/{target_name}"
        if not os.path.exists(sp): 
            print("[CRITICAL] Node integration file missing.")
            sys.exit(1)
        with open(sp, 'r') as sf: old_script = sf.read()
        
        node_uid = safe_extract(r'NODE_UID\s*=\s*"([^"]+)"', old_script)
        notification_key = safe_extract(r'NOTIFICATION_KEY\s*=\s*"([^"]+)"', old_script)
        tag_hash = safe_extract(r'TAG_HASH\s*=\s*"([^"]+)"', old_script)
        tg_chat_id = safe_extract(r'TG_CHAT_ID\s*=\s*"([^"]+)"', old_script, "null")
        
        if not all([node_uid, notification_key, tag_hash]):
            print("[CRITICAL] Integration script is damaged. Refusing update.")
            sys.exit(1)

    script_code = f"""#!/usr/bin/python3
import sys, json, http.client, urllib.parse, hmac, hashlib, time
with open(sys.argv[1], 'r') as f: alert_json = f.read()
NODE_UID, NOTIFICATION_KEY, TAG_HASH = "{node_uid}", "{notification_key}", "{tag_hash}"
TG_CHAT_ID, TG_MIN_LEVEL = "{tg_chat_id}", "{tg_min_level}"
parsed = urllib.parse.urlparse("{WORKER_URL}")
ts = str(int(time.time()))
sig = hmac.new(bytes.fromhex(NOTIFICATION_KEY), (alert_json + ts + NODE_UID).encode('utf-8'), hashlib.sha256).hexdigest()
headers = {{
    "Content-Type": "application/json", 
    "X-Synklav-Signature": sig, 
    "X-Synklav-Timestamp": ts, 
    "X-Synklav-Node-UID": NODE_UID, 
    "X-Synklav-Notification-Key": NOTIFICATION_KEY, 
    "X-Synklav-Tag-Hash": TAG_HASH, 
    "X-Synklav-Telegram-Chat-ID": TG_CHAT_ID,
    "X-Synklav-Telegram-Min-Level": TG_MIN_LEVEL
}}
try:
    conn = http.client.HTTPSConnection(parsed.netloc, timeout=10)
    conn.request("POST", parsed.path if parsed.path else "/", body=alert_json, headers=headers)
    conn.getcall()
    conn.close()
except: sys.exit(0)
"""
    sp = f"/var/ossec/integrations/{target_name}"
    with open(sp, 'w', encoding='utf-8') as sf: sf.write(script_code)
    os.chmod(sp, 0o750)
    try:
        import pwd, grp
        os.chown(sp, pwd.getpwnam('root').pw_uid, grp.getgrnam('wazuh').gr_gid)
    except Exception as e:
        pass

# ------------------------------------------------------------------------------
# REINICIO DEL MOTOR CON EVALUACIÓN DE RETORNO ESTRICTA
# ------------------------------------------------------------------------------
print("[STATUS] Hot-rebooting Wazuh engine process core...")

restart_result = os.system("/var/ossec/bin/wazuh-control restart")

if restart_result != 0:
    print("[CRITICAL] Engine failed to restart safely. Inverting changes...")
    print(f"[STATUS] INITIATING AUTOMATIC TOTAL ROLLBACK TO: {backup_path}...")
    
    shutil.copyfile(backup_path, OSSEC_CONF)
    
    for f_path, content in deleted_scripts_backup.items():
        with open(f_path, 'wb') as f:
            f.write(content)
        os.chmod(f_path, 0o750)
    
    if exec_profile in [1, 2]:
        try: os.remove(f"/var/ossec/integrations/{target_name}")
        except: pass

    os.system("/var/ossec/bin/wazuh-control restart")
    sys.exit(1)

print("====================================================")
print(" ✅ OPERATION VERIFIED AND ACTIVE")
print("====================================================")
