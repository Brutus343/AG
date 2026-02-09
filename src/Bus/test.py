import socket
import struct
import time

# --- CONFIGURATION ---
BUS_HOST = "127.0.0.1"
BUS_PORT = 6950  # Updated Port

def create_ssm_packet(mid, args):
    mid_bytes = mid.encode('utf-8')
    mid_len = len(mid_bytes)

    body = b""
    for key, val in args.items():
        k_bytes = key.encode('utf-8')
        v_bytes = str(val).encode('utf-8')
        
        # 1. Key Length (uint8)
        # 2. Key (string)
        # 3. Value Type (uint8) - 1 is UTF-8 String
        entry_head = struct.pack(f"B{len(k_bytes)}sB", len(k_bytes), k_bytes, 1)
        
        # 4. Value Length (uint24 Big-Endian)
        v_len_bin = struct.pack(">I", len(v_bytes))[1:] 
        
        # 5. Value (string)
        body += entry_head + v_len_bin + v_bytes

    # Header: uint32(len), uint8(opt=0 for map), uint8(mid_len), mid
    total_len = 4 + 1 + 1 + mid_len + len(body)
    header = struct.pack(f">IBB{mid_len}s", total_len, 0, mid_len, mid_bytes)
    
    return header + body

def run_debug_test():
    print(f"Connecting to Bus at {BUS_HOST}:{BUS_PORT}...")
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect((BUS_HOST, BUS_PORT))
        
        # Handshake: The Server sees this
        s.sendall(create_ssm_packet("HELLO", {"name": "PythonDebugger"}))
        print("Sent HELLO...")
        time.sleep(1)

        counter = 1
        while True:
            # Your plugin constants:
            # BUS_MESSAGE_ID = "busComm"
            # args: player, comm
            cmd_mid = "busComm"
            cmd_args = {
                "player": "all",
                "comm": "c MVP"
            }
            
            packet = create_ssm_packet(cmd_mid, cmd_args)
            s.sendall(packet)
            
            # Add a small 0.1s delay between sends if doing multiple,
            # but for this loop, 5s is plenty of time for Perl to clear the buffer.
            print(f"[{time.strftime('%H:%M:%S')}] Sent to busComm: {cmd_args['comm']}")
            
            counter += 1
            time.sleep(5)

    except Exception as e:
        print(f"\n[ERROR] {e}")
    finally:
        s.close()
        input("\nPress Enter to exit.")

if __name__ == "__main__":
    run_debug_test()