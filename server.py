import os
import sys
import json
import shutil
import socket
import threading
import sqlite3
import pickle
import secrets
import uvicorn
import tkinter as tk
from tkinter import messagebox, filedialog
from typing import List
from io import BytesIO
from PIL import Image, ImageTk
import qrcode
import hashlib
import cv2  # 🆕 引入视频处理库

# 引入 AI 库
try:
    from sentence_transformers import SentenceTransformer, util
    HAS_AI = True
except ImportError:
    HAS_AI = False
    print("警告: 未安装 AI 库，智能搜索功能不可用。请运行 pip install sentence-transformers torch")

# 🆕 增加了 Request 和 FileResponse 以支持断点续流和 URL Token
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, FileResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel

CONFIG_FILE = "server_config.json"
DEFAULT_CONFIG = {
    "root_dir": "D:\\MyCloud",
    "username": "admin",
    "password": "123",
    "port": 8000
}
current_config = DEFAULT_CONFIG.copy()
server_thread = None
uvicorn_server = None
app = FastAPI()

# AI 与数据库全局变量
ai_model = None
DB_FILE = "ai_index.db"

# === 鉴权核心配置 ===
# 🆕 auto_error=False 允许请求头为空，以便我们通过 URL 参数获取 Token
security = HTTPBearer(auto_error=False)
VALID_TOKENS = set()  # 内存中存储白名单 Token

def verify_token(request: Request, credentials: HTTPAuthorizationCredentials = Depends(security)):
    """校验每次请求携带的 Token 是否合法 (支持 Header 和 URL 参数)"""
    # 1. 先尝试从 URL 参数获取 token (专门防音视频播放器丢 Header 的问题)
    token = request.query_params.get("token")
    
    # 2. 如果 URL 里没有，再去检查请求头
    if not token and credentials:
        token = credentials.credentials
        
    if token not in VALID_TOKENS:
        raise HTTPException(status_code=401, detail="无效或已过期的 Token，请重新登录")
    return token

def load_config():
    global current_config
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                current_config.update(json.load(f))
        except: pass

def save_config():
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(current_config, f, indent=4)

def get_root_dir(): return current_config["root_dir"]

def init_db():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS photos (path TEXT PRIMARY KEY, mtime REAL, embedding BLOB)''')
    conn.commit()
    conn.close()

def get_ai_model():
    global ai_model
    if not HAS_AI: return None
    if ai_model is None:
        print("正在加载 AI 模型 (clip-ViT-B-32)，首次运行需要下载模型，请耐心等待...")
        ai_model = SentenceTransformer('clip-ViT-B-32') 
        print("AI 模型加载完成！")
    return ai_model

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def read_root(): return {"message": "Private Cloud is Running"}

@app.post("/login")
def login_check(data: dict):
    req_user = data.get("username", "")
    req_pass = data.get("password", "")
    target_user = current_config["username"]
    target_pass = current_config["password"]
    if req_pass == target_pass and (not req_user or req_user == target_user):
        token = secrets.token_hex(32)
        VALID_TOKENS.add(token)
        return {"status": "ok", "token": token}
    else:
        raise HTTPException(status_code=401, detail="用户名或密码错误")

@app.get("/download/{file_path:path}")
def download_file(file_path: str, token: str = Depends(verify_token)):
    root = get_root_dir()
    full_path = os.path.join(root, file_path)
    if not os.path.exists(full_path): return {"error": "File not found"}
    # 🆕 替换为 FileResponse，原生完美支持 HTTP Range (断点音频/视频流)
    return FileResponse(full_path)

@app.get("/thumbnail")
async def get_thumbnail(path: str, token: str = Depends(verify_token)):
    root = get_root_dir()
    full_path = os.path.join(root, path)
    if not os.path.exists(full_path): 
        return StreamingResponse(BytesIO(b""), status_code=404)
    
    # 🆕 1. 建立隐藏的缓存目录
    cache_dir = os.path.join(root, ".cache", "thumbnails")
    os.makedirs(cache_dir, exist_ok=True)
    
    # 🆕 2. 使用文件绝对路径的 MD5 作为缓存文件名 (避免创建复杂的嵌套目录)
    path_hash = hashlib.md5(full_path.encode('utf-8')).hexdigest()
    cache_file = os.path.join(cache_dir, f"{path_hash}.jpg")
    
    # 🆕 3. 检查缓存是否存在，且缓存时间晚于源文件修改时间 (防止原图被覆盖但缩略图没更新)
    if os.path.exists(cache_file) and os.path.getmtime(cache_file) >= os.path.getmtime(full_path):
        return FileResponse(cache_file)
        
    # 🆕 4. 如果没有缓存，则生成它
    try:
        ext = full_path.lower().split('.')[-1]
        
        # 处理视频封面
        if ext in ['mp4', 'mov', 'avi', 'mkv']:
            cap = cv2.VideoCapture(full_path)
            ret, frame = cap.read() # 读取第一帧
            cap.release()
            if ret:
                # 将视频帧压缩并保存为 JPEG 缓存
                frame = cv2.resize(frame, (200, 200), interpolation=cv2.INTER_AREA)
                cv2.imwrite(cache_file, frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
                return FileResponse(cache_file)
            else:
                return StreamingResponse(BytesIO(b""), status_code=500)
                
        # 处理图片缩略图
        else:
            with Image.open(full_path) as img:
                if img.mode == 'RGBA': img = img.convert('RGB')
                img.thumbnail((200, 200))
                img.save(cache_file, 'JPEG', quality=70)
            return FileResponse(cache_file)
            
    except Exception as e: 
        return StreamingResponse(BytesIO(b""), status_code=500)

@app.get("/disk_usage")
def get_disk_usage(token: str = Depends(verify_token)):
    try:
        total, used, free = shutil.disk_usage(get_root_dir())
        return {"total": total, "used": used, "free": free}
    except Exception as e: return {"error": str(e)}

@app.get("/files")
def list_files(path: str = "", token: str = Depends(verify_token)):
    root = get_root_dir()
    full_path = os.path.join(root, path)
    if not os.path.exists(full_path): return {"error": "Path not found"}
    items = []
    try:
        with os.scandir(full_path) as entries:
            for entry in entries:
                stat = entry.stat()
                items.append({
                    "name": entry.name,
                    "is_dir": entry.is_dir(),
                    "size": stat.st_size if not entry.is_dir() else 0,
                    "mtime": stat.st_mtime
                })
    except Exception as e: return {"error": str(e)}
    items.sort(key=lambda x: (not x['is_dir'], x['name']))
    return items

class CheckUploadModel(BaseModel):
    path: str
    filename: str
    total_size: int

@app.post("/check_upload")
def check_upload(data: CheckUploadModel, token: str = Depends(verify_token)):
    root = get_root_dir()
    target_dir = os.path.join(root, data.path)
    final_file = os.path.join(target_dir, data.filename)
    tmp_file = final_file + ".tmp"
    
    if os.path.exists(final_file) and os.path.getsize(final_file) == data.total_size:
        return {"status": "finished", "uploaded": data.total_size}
    if os.path.exists(tmp_file):
        tmp_size = os.path.getsize(tmp_file)
        if tmp_size > data.total_size:
            os.remove(tmp_file)
            return {"status": "new", "uploaded": 0}
        return {"status": "incomplete", "uploaded": tmp_size}
    return {"status": "new", "uploaded": 0}

@app.post("/upload_chunk")
async def upload_chunk(
    path: str = Form(...), filename: str = Form(...),
    offset: int = Form(...), total_size: int = Form(...),
    file: UploadFile = File(...), token: str = Depends(verify_token)
):
    root = get_root_dir()
    target_dir = os.path.join(root, path)
    os.makedirs(target_dir, exist_ok=True)
    final_file = os.path.join(target_dir, filename)
    tmp_file = final_file + ".tmp"
    chunk_data = await file.read()
    
    try:
        if offset == 0:
            with open(tmp_file, "wb") as f: f.write(chunk_data)
        else:
            if not os.path.exists(tmp_file):
                raise HTTPException(status_code=400, detail="Temp file missing")
            with open(tmp_file, "r+b") as f:
                f.seek(offset)
                f.write(chunk_data)
        
        current_size = os.path.getsize(tmp_file)
        if current_size >= total_size:
            if os.path.exists(final_file): os.remove(final_file)
            os.rename(tmp_file, final_file)
            return {"status": "finished"}
        return {"status": "uploading", "uploaded": current_size}
    except Exception as e: return {"error": str(e)}

@app.post("/upload")
async def upload_files(path: str = Form(...), files: List[UploadFile] = File(...), token: str = Depends(verify_token)):
    root = get_root_dir()
    target_dir = os.path.join(root, path)
    os.makedirs(target_dir, exist_ok=True)
    try:
        for file in files:
            file_location = os.path.join(target_dir, file.filename)
            with open(file_location, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)
            file.file.close()
        return {"info": "Success"}
    except Exception as e: return {"error": str(e)}

class CommonModel(BaseModel):
    parent_path: str = ""
    path: str = ""
    file_names: List[str] = []
    folder_name: str = ""
    old_path: str = ""
    new_name: str = ""
    src_path: str = ""
    dest_path: str = ""

class BatchCheckModel(BaseModel):
    paths: List[str]

@app.post("/batch_check_exists")
def batch_check_exists(data: BatchCheckModel, token: str = Depends(verify_token)):
    root = get_root_dir()
    results = []
    for relative_path in data.paths:
        full_path = os.path.join(root, relative_path)
        results.append(os.path.exists(full_path))
    return {"results": results}

@app.get("/index_photos")
def index_photos_endpoint(token: str = Depends(verify_token)):
    if not HAS_AI: return {"error": "AI library not installed"}
    model = get_ai_model()
    root = get_root_dir()
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    indexed_count, errors = 0, 0
    for dirpath, dirnames, filenames in os.walk(root):
        for filename in filenames:
            if filename.lower().endswith(('.jpg', '.jpeg', '.png', '.bmp', '.gif')):
                full_path = os.path.join(dirpath, filename)
                rel_path = os.path.relpath(full_path, root).replace("\\", "/")
                mtime = os.path.getmtime(full_path)
                c.execute("SELECT mtime FROM photos WHERE path=?", (rel_path,))
                row = c.fetchone()
                if row and row[0] == mtime: continue
                try:
                    img = Image.open(full_path)
                    emb = model.encode(img)
                    emb_blob = pickle.dumps(emb)
                    c.execute("INSERT OR REPLACE INTO photos (path, mtime, embedding) VALUES (?, ?, ?)",
                              (rel_path, mtime, emb_blob))
                    indexed_count += 1
                    if indexed_count % 10 == 0: conn.commit()
                except Exception as e: errors += 1
    conn.commit()
    conn.close()
    return {"status": "finished", "indexed": indexed_count, "errors": errors}

class SearchModel(BaseModel):
    query: str
    limit: int = 20

@app.post("/ai_search")
def ai_search_endpoint(data: SearchModel, token: str = Depends(verify_token)):
    if not HAS_AI: return {"error": "AI library not installed"}
    model = get_ai_model()
    text_emb = model.encode(data.query)
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("SELECT path, embedding FROM photos")
    rows = c.fetchall()
    conn.close()
    if not rows: return {"results": []}
    paths = []
    img_embs = []
    for path, emb_blob in rows:
        paths.append(path)
        img_embs.append(pickle.loads(emb_blob))
    scores = util.cos_sim(text_emb, img_embs)[0]
    score_list = scores.tolist()
    combined = list(zip(paths, score_list))
    combined.sort(key=lambda x: x[1], reverse=True)
    results = [{"path": path, "score": score} for path, score in combined[:data.limit]]
    return {"results": results}

@app.post("/batch_delete")
def batch_delete(data: CommonModel, token: str = Depends(verify_token)):
    root = get_root_dir()
    parent = os.path.join(root, data.parent_path)
    count = 0
    for name in data.file_names:
        target = os.path.join(parent, name)
        if os.path.exists(target):
            if os.path.isdir(target): shutil.rmtree(target)
            else: os.remove(target)
            count += 1
    return {"info": f"Deleted {count}"}

@app.post("/mkdir")
def mkdir(data: CommonModel, token: str = Depends(verify_token)):
    target = os.path.join(get_root_dir(), data.path, data.folder_name)
    if os.path.exists(target): return {"error": "Exists"}
    os.makedirs(target)
    return {"info": "Created"}

@app.post("/rename")
def rename(data: CommonModel, token: str = Depends(verify_token)):
    old = os.path.join(get_root_dir(), data.old_path)
    new = os.path.join(os.path.dirname(old), data.new_name)
    if os.path.exists(new): return {"error": "Exists"}
    os.rename(old, new)
    return {"info": "Renamed"}

@app.post("/batch_copy")
def batch_copy(data: CommonModel, token: str = Depends(verify_token)):
    src_dir = os.path.join(get_root_dir(), data.src_path)
    dest_dir = os.path.join(get_root_dir(), data.dest_path)
    count = 0
    for name in data.file_names:
        s = os.path.join(src_dir, name)
        d = os.path.join(dest_dir, name)
        if os.path.exists(s):
            if os.path.isdir(s): shutil.copytree(s, d, dirs_exist_ok=True)
            else: shutil.copy2(s, d)
            count += 1
    return {"info": f"Copied {count}"}

@app.post("/batch_move")
def batch_move(data: CommonModel, token: str = Depends(verify_token)):
    src_dir = os.path.join(get_root_dir(), data.src_path)
    dest_dir = os.path.join(get_root_dir(), data.dest_path)
    count = 0
    for name in data.file_names:
        s = os.path.join(src_dir, name)
        d = os.path.join(dest_dir, name)
        if os.path.exists(s):
            shutil.move(s, d)
            count += 1
    return {"info": f"Moved {count}"}

# === GUI 部分 ===
class ServerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("私有云盘服务端 v6.0 (旗舰影音版)")
        self.root.geometry("500x550")
        self.root.resizable(False, False)
        load_config()
        init_db()
        self.is_running = False

        tk.Label(root, text="☁️ 私有云盘服务器", font=("Microsoft YaHei", 18, "bold"), fg="#333").pack(pady=15)
        setting_frame = tk.LabelFrame(root, text="服务器设置", font=("Microsoft YaHei", 10), padx=10, pady=10)
        setting_frame.pack(fill="x", padx=20)

        tk.Label(setting_frame, text="共享文件夹:").grid(row=0, column=0, sticky="w", pady=5)
        self.path_var = tk.StringVar(value=current_config["root_dir"])
        self.entry_path = tk.Entry(setting_frame, textvariable=self.path_var, width=35)
        self.entry_path.grid(row=0, column=1, padx=5)
        tk.Button(setting_frame, text="选择...", command=self.select_path).grid(row=0, column=2)

        tk.Label(setting_frame, text="管理员账号:").grid(row=1, column=0, sticky="w", pady=5)
        self.user_var = tk.StringVar(value=current_config["username"])
        tk.Entry(setting_frame, textvariable=self.user_var, width=20).grid(row=1, column=1, sticky="w", padx=5)

        tk.Label(setting_frame, text="管理员密码:").grid(row=2, column=0, sticky="w", pady=5)
        self.pass_var = tk.StringVar(value=current_config["password"])
        tk.Entry(setting_frame, textvariable=self.pass_var, width=20).grid(row=2, column=1, sticky="w", padx=5)

        tk.Label(setting_frame, text="服务端口:").grid(row=3, column=0, sticky="w", pady=5)
        self.port_var = tk.StringVar(value=str(current_config["port"]))
        tk.Entry(setting_frame, textvariable=self.port_var, width=10).grid(row=3, column=1, sticky="w", padx=5)

        btn_frame = tk.Frame(root)
        btn_frame.pack(pady=20)
        self.btn_save = tk.Button(btn_frame, text="保存配置", command=self.save_settings, bg="#f0f0f0", width=10)
        self.btn_save.pack(side="left", padx=5)
        self.btn_start = tk.Button(btn_frame, text="启动服务", command=self.toggle_server, bg="#4CAF50", fg="white", font=("Microsoft YaHei", 12, "bold"), width=12, height=2)
        self.btn_start.pack(side="left", padx=5)
        self.btn_qr = tk.Button(btn_frame, text="二维码连接", command=self.show_qr_code, bg="#2196F3", fg="white", font=("Microsoft YaHei", 12), width=10, height=2)
        self.btn_qr.pack(side="left", padx=5)

        self.status_label = tk.Label(root, text="状态: 已停止", fg="red", font=("Microsoft YaHei", 10))
        self.status_label.pack()
        self.ip_label = tk.Label(root, text="", fg="gray")
        self.ip_label.pack()
        self.update_ip_label()
        
        if not HAS_AI:
            tk.Label(root, text="⚠️ 未检测到 AI 库，搜索功能不可用", fg="orange").pack(pady=5)
        else:
            tk.Label(root, text="✨ AI搜图 | 断点续传 | URL Token 鉴权已就绪", fg="purple").pack(pady=5)

    def update_ip_label(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            self.local_ip = s.getsockname()[0]
            s.close()
            self.ip_label.config(text=f"本机 IP: {self.local_ip}")
        except: 
            self.local_ip = "127.0.0.1"
            self.ip_label.config(text="无法获取本机 IP")

    def select_path(self):
        path = filedialog.askdirectory()
        if path: self.path_var.set(path)

    def save_settings(self):
        current_config["root_dir"] = self.path_var.get()
        current_config["username"] = self.user_var.get()
        current_config["password"] = self.pass_var.get()
        try: current_config["port"] = int(self.port_var.get())
        except: 
            messagebox.showerror("错误", "端口必须是数字")
            return
        save_config()
        messagebox.showinfo("成功", "配置已保存！")

    def show_qr_code(self):
        self.update_ip_label()
        data = { "ip": f"http://{self.local_ip}:{self.port_var.get()}", "user": self.user_var.get(), "pwd": self.pass_var.get() }
        json_data = json.dumps(data)
        qr = qrcode.QRCode(version=1, box_size=10, border=2)
        qr.add_data(json_data)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        top = tk.Toplevel(self.root)
        top.title("App 扫码连接")
        top.geometry("350x400")
        tk_img = ImageTk.PhotoImage(img)
        lbl = tk.Label(top, image=tk_img)
        lbl.image = tk_img
        lbl.pack(pady=20)
        tk.Label(top, text="请使用 App 登录页的“扫一扫”", font=("Microsoft YaHei", 12)).pack()

    def toggle_server(self):
        if not self.is_running:
            self.save_settings()
            if not os.path.exists(current_config["root_dir"]):
                messagebox.showerror("错误", "共享文件夹路径不存在！")
                return
            self.btn_start.config(text="停止服务", bg="#F44336")
            self.status_label.config(text="状态: 运行中 🟢", fg="green")
            self.lock_ui(True)
            self.is_running = True
            thread = threading.Thread(target=self.run_uvicorn)
            thread.daemon = True
            thread.start()
        else:
            if uvicorn_server: uvicorn_server.should_exit = True
            self.btn_start.config(text="启动服务", bg="#4CAF50")
            self.status_label.config(text="状态: 已停止 🔴", fg="red")
            self.lock_ui(False)
            self.is_running = False

    def run_uvicorn(self):
        global uvicorn_server
        config = uvicorn.Config(app, host="0.0.0.0", port=current_config["port"], log_level="info")
        uvicorn_server = uvicorn.Server(config)
        uvicorn_server.run()

    def lock_ui(self, locked):
        state = "disabled" if locked else "normal"
        self.entry_path.config(state=state)

if __name__ == "__main__":
    root = tk.Tk()
    app_gui = ServerApp(root)
    root.mainloop()
