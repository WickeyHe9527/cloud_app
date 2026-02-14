import os
import sys
import json
import shutil
import socket
import threading
import sqlite3
import pickle
import uvicorn
import tkinter as tk
from tkinter import messagebox, filedialog
from typing import List
from io import BytesIO
from PIL import Image, ImageTk
import qrcode

# 🆕 引入 AI 库 (如果是第一次运行，会有点慢)
try:
    from sentence_transformers import SentenceTransformer, util
    HAS_AI = True
except ImportError:
    HAS_AI = False
    print("警告: 未安装 AI 库，智能搜索功能不可用。请运行 pip install sentence-transformers torch")

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

# ... (基础配置保持不变) ...
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

# 🆕 AI 全局变量
ai_model = None
DB_FILE = "ai_index.db"

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

# 🆕 初始化数据库
def init_db():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    # 创建表：路径, 修改时间, 向量数据
    c.execute('''CREATE TABLE IF NOT EXISTS photos 
                 (path TEXT PRIMARY KEY, mtime REAL, embedding BLOB)''')
    conn.commit()
    conn.close()

# 🆕 加载 AI 模型 (懒加载，用到时再载入)
def get_ai_model():
    global ai_model
    if not HAS_AI: return None
    if ai_model is None:
        print("正在加载 AI 模型 (clip-ViT-B-32)，首次运行需要下载模型，请耐心等待...")
        # 支持中文的多语言 CLIP 模型
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
    if req_pass == target_pass:
        if req_user and req_user != target_user:
             raise HTTPException(status_code=401, detail="用户名或密码错误")
        return {"status": "ok"}
    else:
        raise HTTPException(status_code=401, detail="用户名或密码错误")

@app.get("/download/{file_path:path}")
def download_file(file_path: str):
    root = get_root_dir()
    full_path = os.path.join(root, file_path)
    if not os.path.exists(full_path): return {"error": "File not found"}
    return StreamingResponse(open(full_path, "rb"))

@app.get("/thumbnail")
async def get_thumbnail(path: str):
    root = get_root_dir()
    full_path = os.path.join(root, path)
    if not os.path.exists(full_path): return StreamingResponse(BytesIO(b""), status_code=404)
    try:
        with Image.open(full_path) as img:
            if img.mode == 'RGBA': img = img.convert('RGB')
            img.thumbnail((200, 200))
            img_io = BytesIO()
            img.save(img_io, 'JPEG', quality=70)
            img_io.seek(0)
            return StreamingResponse(img_io, media_type="image/jpeg")
    except: return StreamingResponse(BytesIO(b""), status_code=500)

@app.get("/disk_usage")
def get_disk_usage():
    try:
        total, used, free = shutil.disk_usage(get_root_dir())
        return {"total": total, "used": used, "free": free}
    except Exception as e: return {"error": str(e)}

@app.get("/files")
def list_files(path: str = ""):
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

@app.post("/upload")
async def upload_files(path: str = Form(...), files: List[UploadFile] = File(...)):
    root = get_root_dir()
    target_dir = os.path.join(root, path)
    if not os.path.exists(target_dir):
        try: os.makedirs(target_dir)
        except Exception as e: return {"error": f"Failed to create directory: {str(e)}"}     
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
def batch_check_exists(data: BatchCheckModel):
    root = get_root_dir()
    results = []
    for relative_path in data.paths:
        full_path = os.path.join(root, relative_path)
        results.append(os.path.exists(full_path))
    return {"results": results}

# === 🆕 AI 核心接口 ===

# 1. 触发 AI 索引 (扫描文件夹，分析未分析的图片)
@app.get("/index_photos")
def index_photos_endpoint():
    if not HAS_AI: return {"error": "AI library not installed"}
    model = get_ai_model()
    root = get_root_dir()
    
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    
    indexed_count = 0
    errors = 0
    
    # 遍历所有文件
    for dirpath, dirnames, filenames in os.walk(root):
        for filename in filenames:
            if filename.lower().endswith(('.jpg', '.jpeg', '.png', '.bmp', '.gif')):
                full_path = os.path.join(dirpath, filename)
                rel_path = os.path.relpath(full_path, root).replace("\\", "/")
                mtime = os.path.getmtime(full_path)
                
                # 检查是否已分析且未修改
                c.execute("SELECT mtime FROM photos WHERE path=?", (rel_path,))
                row = c.fetchone()
                if row and row[0] == mtime:
                    continue # 已存在且没变，跳过
                
                # 开始分析
                try:
                    img = Image.open(full_path)
                    # 计算向量 (Embedding)
                    emb = model.encode(img)
                    # 存入数据库 (使用 pickle 序列化向量)
                    emb_blob = pickle.dumps(emb)
                    c.execute("INSERT OR REPLACE INTO photos (path, mtime, embedding) VALUES (?, ?, ?)",
                              (rel_path, mtime, emb_blob))
                    indexed_count += 1
                    # 每处理 10 张提交一次，防止卡死
                    if indexed_count % 10 == 0: conn.commit()
                except Exception as e:
                    print(f"Error processing {rel_path}: {e}")
                    errors += 1
    
    conn.commit()
    conn.close()
    return {"status": "finished", "indexed": indexed_count, "errors": errors}

# 2. AI 搜索接口
class SearchModel(BaseModel):
    query: str
    limit: int = 20

@app.post("/ai_search")
def ai_search_endpoint(data: SearchModel):
    if not HAS_AI: return {"error": "AI library not installed"}
    model = get_ai_model()
    
    # 1. 把文字变成向量
    text_emb = model.encode(data.query)
    
    # 2. 从数据库取出所有图片向量
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
    
    # 3. 计算相似度 (Cosine Similarity)
    # util.cos_sim 返回的是一个矩阵，我们取第一行
    scores = util.cos_sim(text_emb, img_embs)[0]
    
    # 4. 排序并取前 N 个
    # torch.topk 可以快速取前几名
    top_results = []
    # 简单的 python 排序 (为了不依赖 torch 的复杂 tensor 操作，这里转成 list 处理)
    score_list = scores.tolist()
    combined = list(zip(paths, score_list))
    # 按分数降序排
    combined.sort(key=lambda x: x[1], reverse=True)
    
    # 取前 N 个，且分数要大于一定阈值 (比如 0.2) 过滤掉完全不相关的
    results = []
    for path, score in combined[:data.limit]:
        results.append({"path": path, "score": score})
        
    return {"results": results}

# ... (其余基础接口 batch_delete, mkdir 等保持不变，为节省篇幅略去，请保留原有的) ...
@app.post("/batch_delete")
def batch_delete(data: CommonModel):
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
def mkdir(data: CommonModel):
    target = os.path.join(get_root_dir(), data.path, data.folder_name)
    if os.path.exists(target): return {"error": "Exists"}
    os.makedirs(target)
    return {"info": "Created"}

@app.post("/rename")
def rename(data: CommonModel):
    old = os.path.join(get_root_dir(), data.old_path)
    new = os.path.join(os.path.dirname(old), data.new_name)
    if os.path.exists(new): return {"error": "Exists"}
    os.rename(old, new)
    return {"info": "Renamed"}

@app.post("/batch_copy")
def batch_copy(data: CommonModel):
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
def batch_move(data: CommonModel):
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

# === GUI 部分 (保持不变) ===
class ServerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("私有云盘服务端 v4.0 (AI 旗舰版)")
        self.root.geometry("500x550")
        self.root.resizable(False, False)
        load_config()
        init_db() # 初始化数据库
        self.is_running = False

        tk.Label(root, text="☁️ 私有云盘服务器", font=("Microsoft YaHei", 18, "bold"), fg="#333").pack(pady=15)
        setting_frame = tk.LabelFrame(root, text="服务器设置", font=("Microsoft YaHei", 10), padx=10, pady=10)
        setting_frame.pack(fill="x", padx=20)

        tk.Label(setting_frame, text="共享文件夹路径:").grid(row=0, column=0, sticky="w", pady=5)
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
        
        # 提示信息
        if not HAS_AI:
            tk.Label(root, text="⚠️ 未检测到 AI 库，搜索功能不可用", fg="orange").pack(pady=5)
        else:
            tk.Label(root, text="✨ AI 智能搜索已就绪 (首次搜索需加载模型)", fg="purple").pack(pady=5)

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
