import requests
import socket
import struct
import time
from datetime import datetime, timedelta
from bs4 import BeautifulSoup
import urllib3

# --- SETTINGS ---
BUS_HOST = "127.0.0.1"
BUS_PORT = 6950
MVP_URL = "https://asgardsglory.ddns.net/?module=ranking&action=mvp"
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- MVP DATABASE ---
MVP_DB = {
    "Golden Thief Bug": ["prt_sewb4", 70],
    "Eddga": ["pay_fild11", 130],
    "Tao Gunka": ["beach_dun", 310],
    "Osiris": ["moc_pryd04", 70],
    "Phreeoni": ["moc_fild17", 130],
    "Mistress": ["mjolnir_04", 130],
    "Maya": ["anthell02", 130],
    "Drake": ["treasure02", 130],
    "Moonlight Flower": ["pay_dun04", 70],
    "Pharaoh": ["in_sphinx5", 70],
    "Orc Hero": ["gef_fild14", 70],
    "Orc Lord": ["gef_fild10", 130],
    "Stormy Knight": ["xmas_dun02", 70],
    "Hatii": ["xmas_fild01", 130],
    "Turtle General": ["tur_dun04", 70],
    "Baphomet": ["prt_maze03", 130],
    "Dark Lord": ["gl_chyard", 70],
    "Lord of Death": ["niflheim", 133],
}

death_announced = {}  # Changed to dict to store timestamps
spawn_announced = {}  # Track announced spawns

def create_ssm_packet(mid, args):
    mid_bytes = mid.encode('utf-8')
    mid_len = len(mid_bytes)
    body = b""
    for key, val in args.items():
        k_bytes = key.encode('utf-8')
        v_bytes = str(val).encode('utf-8')
        entry_head = struct.pack(f"B{len(k_bytes)}sB", len(k_bytes), k_bytes, 1)
        v_len_bin = struct.pack(">I", len(v_bytes))[1:]
        body += entry_head + v_len_bin + v_bytes
    total_len = 4 + 1 + 1 + mid_len + len(body)
    header = struct.pack(f">IBB{mid_len}s", total_len, 0, mid_len, mid_bytes)
    return header + body

def send_to_bus(message_text, s):
    try:
        cmd_mid = "busComm"
        cmd_args = {
            "player": "all",
            "comm": "p " + message_text
        }
        packet = create_ssm_packet(cmd_mid, cmd_args)
        s.sendall(packet)
        return True
    except Exception as e:
        print(f"   [!] Bus send failed: {e}")
        return False

def connect_to_bus():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((BUS_HOST, BUS_PORT))
        s.sendall(create_ssm_packet("HELLO", {"name": "MVPTracker"}))
        print(f"   [+] Connected to OpenKore bus")
        return s
    except Exception as e:
        print(f"   [!] Bus connection failed: {e}")
        return None

def cleanup_old_announcements():
    """Remove old entries from tracking dicts to prevent memory bloat"""
    current_time = datetime.now()
    cutoff = timedelta(hours=6)  # Clean up anything older than 6 hours
    
    # Clean death announcements
    to_remove = [k for k, v in death_announced.items() 
                 if current_time - v > cutoff]
    for k in to_remove:
        del death_announced[k]
    
    # Clean spawn announcements
    to_remove = [k for k, v in spawn_announced.items() 
                 if current_time - v > cutoff]
    for k in to_remove:
        del spawn_announced[k]
    
    if to_remove:
        print(f"   [Cleanup] Removed {len(to_remove)} old announcement entries")

def run_tracker():
    bus_socket = connect_to_bus()
    last_cleanup = datetime.now()
    
    while True:
        # Reconnect to bus if disconnected
        if bus_socket is None:
            print("   [!] Attempting to reconnect to bus...")
            time.sleep(10)
            bus_socket = connect_to_bus()
            continue

        # Periodic cleanup (every hour)
        if datetime.now() - last_cleanup > timedelta(hours=1):
            cleanup_old_announcements()
            last_cleanup = datetime.now()

        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Scraping for Deaths/Spawns...")
        try:
            response = requests.get(MVP_URL, verify=False, timeout=15)
            soup = BeautifulSoup(response.text, 'html.parser')
            all_cols = soup.find_all('td')
            
            match_count = 0
            processed_mvps = set()

            for i, col in enumerate(all_cols):
                site_text = col.text.strip()
                
                for db_name, data in MVP_DB.items():
                    if db_name.lower() == site_text.lower() and db_name not in processed_mvps:
                        match_count += 1
                        processed_mvps.add(db_name)
                        map_name, respawn_mins = data
                        
                        killed_at_str = None
                        for offset in range(1, 6):
                            prev_idx = i - offset
                            if prev_idx >= 0:
                                potential_date = all_cols[prev_idx].text.strip()
                                if "-" in potential_date and ":" in potential_date:
                                    killed_at_str = potential_date
                                    break
                        
                        if killed_at_str:
                            killed_at = datetime.strptime(killed_at_str, '%Y-%m-%d %H:%M:%S')
                            spawn_time = killed_at + timedelta(minutes=respawn_mins)
                            kill_id = f"{db_name}_{killed_at_str}"
                            time_since_death = datetime.now() - killed_at
                            
                            # LOGIC 1: DEATH ALERT
                            if time_since_death < timedelta(minutes=2) and kill_id not in death_announced:
                                death_msg = f'   [!!!] DEAD: "{db_name}" just died at {killed_at_str[-8:]}!'
                                print(death_msg)
                                if send_to_bus(death_msg, bus_socket):
                                    death_announced[kill_id] = datetime.now()
                                else:
                                    # Reconnect on failure
                                    bus_socket = connect_to_bus()
                                continue  # Don't report "UP" if it just died

                            # LOGIC 2: SPAWN ALERT
                            if datetime.now() >= spawn_time:
                                # Only announce once per spawn window (use killed_at_str as unique ID)
                                if killed_at_str not in spawn_announced:
                                    spawn_msg = f'   >>> ALERT: "{db_name}" is UP at {map_name}!'
                                    print(spawn_msg)
                                    if send_to_bus(spawn_msg, bus_socket):
                                        spawn_announced[killed_at_str] = datetime.now()
                                    else:
                                        # Reconnect on failure
                                        bus_socket = connect_to_bus()
                                else:
                                    # Already announced, just show it's still up
                                    print(f"   [UP] {db_name.ljust(22)} - Still active at {map_name}")
                            else:
                                # LOGIC 3: RESTORED STATUS OUTPUT
                                print(f"   [Latest] {db_name.ljust(18)} - Spawn: {spawn_time.strftime('%H:%M:%S')} (Killed: {killed_at_str[-8:]})")

            print(f"Done. Successfully matched {match_count} unique MVPs.")

        except Exception as e:
            print(f"!!! Error: {e}")

        time.sleep(60)

if __name__ == "__main__":
    run_tracker()