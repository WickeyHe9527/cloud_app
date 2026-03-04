import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

// 引入后台任务管理器
import 'package:workmanager/workmanager.dart';

// === 全局状态与管理器 ===
final AudioPlayer _globalAudioPlayer = AudioPlayer();
String _currentPlayingName = "";
final TransferManager globalTransferManager = TransferManager();

// =========================================================================
// 🚀 完全独立运行的后台幽灵进程（用于夜间 Wi-Fi 充电静默备份）
// =========================================================================
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != "autoBackupTask") return Future.value(true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final serverUrl = prefs.getString('server_ip');
      final token = prefs.getString('server_token');
      final autoSyncEnabled = prefs.getBool('auto_sync_enabled') ?? false;

      // 如果未登录或关闭了自动备份，则停止
      if (serverUrl == null || token == null || !autoSyncEnabled) {
        return Future.value(true);
      }

      // 后台获取相册权限并读取
      List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
      );
      if (albums.isEmpty) return Future.value(true);

      // 只扫描最近的 500 张照片进行比对，防止后台任务超时被系统强杀
      List<AssetEntity> latestAssets = await albums[0].getAssetListRange(
        start: 0,
        end: 500,
      );
      List<String> assetIds = latestAssets.map((e) => e.id).toList();

      // 本地 SQLite 极速过滤
      Set<String> localSyncedIds = await SyncDatabase.getSyncedIds(assetIds);
      List<AssetEntity> toUpload = latestAssets
          .where((a) => !localSyncedIds.contains(a.id))
          .toList();

      if (toUpload.isEmpty) return Future.value(true); // 全都传过了，直接收工睡觉

      // 开始静默上传
      final client = http.Client();
      for (var asset in toUpload) {
        File? file = await asset.file;
        if (file == null) continue;

        DateTime date = asset.createDateTime;
        String targetFolder =
            "相册备份/${date.year}年${date.month.toString().padLeft(2, '0')}月/${asset.type == AssetType.video ? "视频" : "图片"}";
        String fileName = file.path.split(Platform.pathSeparator).last;
        int totalSize = await file.length();

        // 断点续传检测
        var checkRes = await client.post(
          Uri.parse('$serverUrl/check_upload'),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer $token",
          },
          body: jsonEncode({
            "path": targetFolder,
            "filename": fileName,
            "total_size": totalSize,
          }),
        );

        if (checkRes.statusCode == 200) {
          var data = jsonDecode(checkRes.body);
          if (data['status'] == 'finished') {
            await SyncDatabase.markSynced(asset.id);
            continue;
          }

          int uploaded = data['uploaded'] ?? 0;
          RandomAccessFile raf = await file.open(mode: FileMode.read);
          bool success = true;

          try {
            while (uploaded < totalSize) {
              raf.setPositionSync(uploaded);
              int currentChunkSize = (totalSize - uploaded) > 5 * 1024 * 1024
                  ? 5 * 1024 * 1024
                  : (totalSize - uploaded);
              List<int> chunk = raf.readSync(currentChunkSize);

              var request = http.MultipartRequest(
                'POST',
                Uri.parse('$serverUrl/upload_chunk'),
              );
              request.headers['Authorization'] = 'Bearer $token';
              request.fields['path'] = targetFolder;
              request.fields['filename'] = fileName;
              request.fields['offset'] = uploaded.toString();
              request.fields['total_size'] = totalSize.toString();
              request.files.add(
                http.MultipartFile.fromBytes('file', chunk, filename: fileName),
              );

              var response = await client
                  .send(request)
                  .timeout(const Duration(seconds: 30));
              if (response.statusCode == 200) {
                uploaded += currentChunkSize;
              } else {
                success = false;
                break;
              }
            }
          } catch (e) {
            success = false;
          } finally {
            raf.closeSync();
          }

          if (success) await SyncDatabase.markSynced(asset.id); // 上传成功，打卡
        }
      }
      client.close();
    } catch (e) {
      debugPrint("后台静默同步异常: $e");
    }
    return Future.value(true);
  });
}
// =========================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化锁屏音频中心
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.example.cloud_app.audio',
      androidNotificationChannelName: '私有云音乐',
      androidNotificationOngoing: true,
    );
  } catch (e) {
    debugPrint("后台音频初始化提醒: $e");
  }

  // 注册后台任务引擎
  try {
    Workmanager().initialize(callbackDispatcher);
  } catch (e) {
    debugPrint("Workmanager init failed: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '私有云盘 旗舰版',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const ConnectPage(),
    );
  }
}

// === 后台传输任务管理器 (带本地持久化) ===
enum TaskType { upload, download, sync }

class TransferTask {
  final String id = DateTime.now().millisecondsSinceEpoch.toString();
  final String name;
  final TaskType type;
  final Future<void> Function(TransferTask task) execute;

  double progress = 0.0;
  String statusText = "排队中...";
  bool isRunning = false;
  bool isDone = false;
  bool isError = false;
  bool isCanceled = false;
  http.Client? client;

  TransferTask({required this.name, required this.type, required this.execute});

  void cancel() {
    isCanceled = true;
    statusText = "已取消";
    client?.close();
    globalTransferManager.saveHistory();
    globalTransferManager.notifyListeners();
  }
}

class TransferManager extends ChangeNotifier {
  List<TransferTask> tasks = [];
  bool _isProcessingQueue = false;

  TransferManager() {
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? history = prefs.getStringList('transfer_history');
    if (history != null) {
      for (var str in history) {
        try {
          var map = jsonDecode(str);
          var task = TransferTask(
            name: map['name'],
            type: TaskType.values[map['type']],
            execute: (t) async {},
          );
          task.progress = map['progress'] ?? 0.0;
          task.statusText = map['statusText'] ?? '';
          task.isDone = map['isDone'] ?? false;
          task.isError = map['isError'] ?? false;
          task.isCanceled = map['isCanceled'] ?? false;
          if (!task.isDone && !task.isError && !task.isCanceled) {
            task.isError = true;
            task.statusText = "App意外关闭，传输中断";
          }
          tasks.add(task);
        } catch (e) {}
      }
      notifyListeners();
    }
  }

  Future<void> saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = tasks
        .map(
          (t) => jsonEncode({
            'name': t.name,
            'type': t.type.index,
            'progress': t.progress,
            'statusText': t.statusText,
            'isDone': t.isDone,
            'isError': t.isError,
            'isCanceled': t.isCanceled,
          }),
        )
        .toList();
    await prefs.setStringList('transfer_history', history);
  }

  void addTask(TransferTask task) {
    tasks.insert(0, task);
    saveHistory();
    notifyListeners();
    _processQueue();
  }

  int get activeCount =>
      tasks.where((t) => !t.isDone && !t.isError && !t.isCanceled).length;

  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    WakelockPlus.enable();

    while (true) {
      var pendingTasks = tasks
          .where(
            (t) => !t.isRunning && !t.isDone && !t.isError && !t.isCanceled,
          )
          .toList();
      if (pendingTasks.isEmpty) break;

      var task = pendingTasks.last;
      task.isRunning = true;
      task.statusText = "准备处理...";
      notifyListeners();

      try {
        await task.execute(task);
        if (!task.isCanceled) {
          task.isDone = true;
          task.progress = 1.0;
          task.statusText = "已完成";
        }
      } catch (e) {
        if (!task.isCanceled) {
          task.isError = true;
          task.statusText = "失败: ${e.toString().split('\n')[0]}";
        }
      } finally {
        task.isRunning = false;
        task.client?.close();
        saveHistory();
        notifyListeners();
      }
    }
    _isProcessingQueue = false;
    WakelockPlus.disable();
  }

  void clearCompleted() {
    tasks.removeWhere((t) => t.isDone || t.isCanceled || t.isError);
    saveHistory();
    notifyListeners();
  }
}

// === 本地同步记录数据库类 ===
class SyncDatabase {
  static Database? _db;
  static Future<Database> get database async {
    if (_db != null) return _db!;
    String dbPath = p.join(await getDatabasesPath(), 'sync_history.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE synced_assets (id TEXT PRIMARY KEY)');
      },
    );
    return _db!;
  }

  static Future<void> markSynced(String id) async {
    final db = await database;
    await db.insert('synced_assets', {
      'id': id,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Set<String>> getSyncedIds(List<String> ids) async {
    if (ids.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final res = await db.query(
      'synced_assets',
      columns: ['id'],
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return res.map((e) => e['id'] as String).toSet();
  }
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _ipController = TextEditingController();
  final _userController = TextEditingController();
  final _pwdController = TextEditingController();
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _loadSavedInfo();
  }

  Future<void> _loadSavedInfo() async {
    final prefs = await SharedPreferences.getInstance();
    _ipController.text =
        prefs.getString('server_ip') ?? "http://192.168.1.100:8000";
    _userController.text = prefs.getString('server_user') ?? "admin";
    _pwdController.text = prefs.getString('server_pwd') ?? "";
  }

  Future<void> _connect() async {
    String ip = _ipController.text.trim();
    String user = _userController.text.trim();
    String pwd = _pwdController.text.trim();
    if (!ip.startsWith('http')) ip = 'http://$ip';
    if (pwd.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入密码')));
      return;
    }

    setState(() => _isConnecting = true);

    try {
      final response = await http
          .post(
            Uri.parse('$ip/login'),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"username": user, "password": pwd}),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        String token = jsonDecode(response.body)['token'] ?? "dummy_token";
        // 修正：Python服务端目前未返回token，如果后续实现JWT，此处将接收真实token
        await prefs.setString('server_token', token);
        await prefs.setString('server_ip', ip);
        await prefs.setString('server_user', user);
        await prefs.setString('server_pwd', pwd);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) =>
                FileListPage(currentPath: "", serverUrl: ip, token: token),
          ),
        );
      } else if (response.statusCode == 401) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('用户名或密码错误')));
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连接失败，请检查网络')));
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _openScanner() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QRScanPage()),
    );
    if (result != null) {
      try {
        Map<String, dynamic> data = jsonDecode(result);
        if (data.containsKey('ip') && data.containsKey('pwd')) {
          setState(() {
            _ipController.text = data['ip'];
            _userController.text = data['user'] ?? "admin";
            _pwdController.text = data['pwd'];
          });
          _connect();
        }
      } catch (e) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("连接私有云")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.cloud_circle, size: 80, color: Colors.blue),
            const SizedBox(height: 20),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: "服务器地址",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _userController,
              decoration: const InputDecoration(
                labelText: "用户名",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _pwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "密码",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _isConnecting ? null : _connect,
                      child: const Text("登录"),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                SizedBox(
                  height: 50,
                  width: 60,
                  child: FilledButton.tonal(
                    onPressed: _openScanner,
                    child: const Icon(Icons.qr_code_scanner),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class QRScanPage extends StatelessWidget {
  const QRScanPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("扫码连接")),
      body: MobileScanner(
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            if (barcode.rawValue != null) {
              Navigator.pop(context, barcode.rawValue);
              break;
            }
          }
        },
      ),
    );
  }
}

class SmartSearchPage extends StatefulWidget {
  final String serverUrl;
  final String token;
  const SmartSearchPage({
    super.key,
    required this.serverUrl,
    required this.token,
  });
  @override
  State<SmartSearchPage> createState() => _SmartSearchPageState();
}

class _SmartSearchPageState extends State<SmartSearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<dynamic> _results = [];
  bool _isSearching = false, _isIndexing = false;

  Future<void> _startIndexing() async {
    setState(() => _isIndexing = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('AI 正在学习你的照片...')));
    try {
      final response = await http
          .get(
            Uri.parse('${widget.serverUrl}/index_photos'),
            headers: {"Authorization": "Bearer ${widget.token}"},
          )
          .timeout(const Duration(minutes: 30));
      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '学习完成！已索引 ${jsonDecode(response.body)['indexed']} 张照片',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('索引指令已发送 (后台运行中)')));
    } finally {
      if (mounted) setState(() => _isIndexing = false);
    }
  }

  Future<void> _doSearch() async {
    if (_controller.text.isEmpty) return;
    setState(() => _isSearching = true);
    try {
      final response = await http.post(
        Uri.parse('${widget.serverUrl}/ai_search'),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${widget.token}",
        },
        body: jsonEncode({"query": _controller.text, "limit": 50}),
      );
      if (response.statusCode == 200) {
        setState(
          () =>
              _results = jsonDecode(utf8.decode(response.bodyBytes))['results'],
        );
      }
    } catch (e) {
    } finally {
      setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI 智能搜图"),
        actions: [
          _isIndexing
              ? const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: CircularProgressIndicator(),
                )
              : IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _startIndexing,
                ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: "试试搜索: 猫、海边...",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _doSearch,
                ),
                border: const OutlineInputBorder(),
                filled: true,
              ),
              onSubmitted: (_) => _doSearch(),
            ),
          ),
          if (_isSearching) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      "输入关键词，AI 帮你找照片",
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: _results.length,
                    itemBuilder: (ctx, index) {
                      var item = _results[index];
                      String url =
                          "${widget.serverUrl}/thumbnail?path=${Uri.encodeComponent(item['path'])}";
                      return InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ImagePage(
                                url:
                                    "${widget.serverUrl}/download/${Uri.encodeComponent(item['path'])}?token=${widget.token}",
                                token: widget.token,
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CachedNetworkImage(
                                imageUrl: url,
                                httpHeaders: {
                                  "Authorization": "Bearer ${widget.token}",
                                },
                                fit: BoxFit.cover,
                                errorWidget: (c, u, e) =>
                                    const Icon(Icons.broken_image),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  color: Colors.black54,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    "匹配: ${(item['score'] * 100).toInt()}%",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class TransferPage extends StatelessWidget {
  const TransferPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("传输中心"),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: "清除已完成",
            onPressed: () => globalTransferManager.clearCompleted(),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: globalTransferManager,
        builder: (context, child) {
          if (globalTransferManager.tasks.isEmpty)
            return const Center(
              child: Text("暂无传输任务", style: TextStyle(color: Colors.grey)),
            );
          return ListView.builder(
            itemCount: globalTransferManager.tasks.length,
            itemBuilder: (context, index) {
              final task = globalTransferManager.tasks[index];
              IconData icon = task.type == TaskType.upload
                  ? Icons.upload_file
                  : (task.type == TaskType.download
                        ? Icons.download
                        : Icons.sync);
              Color color = task.type == TaskType.upload
                  ? Colors.orange
                  : (task.type == TaskType.download
                        ? Colors.green
                        : Colors.blue);
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: ListTile(
                  leading: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: task.isRunning ? null : task.progress,
                        color: color,
                        backgroundColor: Colors.grey[200],
                      ),
                      Icon(icon, size: 20, color: color),
                    ],
                  ),
                  title: Text(
                    task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          task.statusText,
                          style: TextStyle(
                            color: task.isError ? Colors.red : Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        "${(task.progress * 100).toInt()}%",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  trailing: (!task.isDone && !task.isError && !task.isCanceled)
                      ? IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          onPressed: () => task.cancel(),
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

enum SortType { name, size, date }

List<String> _globalClipboardFiles = [];
String _globalClipboardSourcePath = "";
bool _globalIsCutOperation = false;

class FileListPage extends StatefulWidget {
  final String currentPath;
  final String serverUrl;
  final String token;
  const FileListPage({
    super.key,
    required this.currentPath,
    required this.serverUrl,
    required this.token,
  });
  @override
  State<FileListPage> createState() => _FileListPageState();
}

class _FileListPageState extends State<FileListPage> {
  List<dynamic> _allFiles = [];
  List<dynamic> _displayFiles = [];
  bool isLoading = true,
      _isGridView = false,
      _isSelectionMode = false,
      _isSearching = false;
  final Set<String> _selectedFiles = {};
  Map<String, dynamic>? _diskInfo;
  final TextEditingController _searchController = TextEditingController();
  SortType _sortType = SortType.name;
  bool _isAscending = true;
  bool _autoSyncEnabled = false;

  @override
  void initState() {
    super.initState();
    fetchFiles();
    _fetchDiskUsage();
    _searchController.addListener(_applyFilterAndSort);
    globalTransferManager.addListener(_onTransferManagerChanged);

    // 初始化时加载开关状态
    SharedPreferences.getInstance().then((prefs) {
      if (mounted)
        setState(
          () => _autoSyncEnabled = prefs.getBool('auto_sync_enabled') ?? false,
        );
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    globalTransferManager.removeListener(_onTransferManagerChanged);
    super.dispose();
  }

  void _onTransferManagerChanged() {
    if (globalTransferManager.activeCount == 0 && mounted) fetchFiles();
  }

  Future<void> _playAudio(String fileName, String url) async {
    setState(() {
      _currentPlayingName = fileName;
    });
    try {
      await _globalAudioPlayer.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          tag: MediaItem(
            id: url,
            title: fileName,
            album: "我的私有云",
            artUri: Uri.parse(
              "https://ui-avatars.com/api/?name=Music&background=random&size=512",
            ),
          ),
        ),
      );
      _globalAudioPlayer.play();
      _showAudioPlayerSheet();
    } catch (e) {}
  }

  void _showAudioPlayerSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            height: 220,
            child: Column(
              children: [
                Text(
                  _currentPlayingName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                StreamBuilder<Duration>(
                  stream: _globalAudioPlayer.positionStream,
                  builder: (context, snapshot) {
                    final position = snapshot.data ?? Duration.zero;
                    final duration =
                        _globalAudioPlayer.duration ?? Duration.zero;
                    return Column(
                      children: [
                        Slider(
                          value: position.inSeconds.toDouble().clamp(
                            0.0,
                            duration.inSeconds.toDouble(),
                          ),
                          max: duration.inSeconds.toDouble() > 0
                              ? duration.inSeconds.toDouble()
                              : 1.0,
                          onChanged: (val) => _globalAudioPlayer.seek(
                            Duration(seconds: val.toInt()),
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(position),
                              style: const TextStyle(color: Colors.grey),
                            ),
                            Text(
                              _formatDuration(duration),
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 60),
                    StreamBuilder<PlayerState>(
                      stream: _globalAudioPlayer.playerStateStream,
                      builder: (context, snapshot) {
                        final playing = snapshot.data?.playing ?? false;
                        return IconButton(
                          iconSize: 60,
                          icon: Icon(
                            playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            color: Colors.blue,
                          ),
                          onPressed: () => playing
                              ? _globalAudioPlayer.pause()
                              : _globalAudioPlayer.play(),
                        );
                      },
                    ),
                    Container(
                      width: 60,
                      alignment: Alignment.centerRight,
                      child: StreamBuilder<double>(
                        stream: _globalAudioPlayer.speedStream,
                        builder: (context, snapshot) {
                          final speed = snapshot.data ?? 1.0;
                          return TextButton(
                            onPressed: () {
                              double newSpeed = speed == 1.0
                                  ? 1.25
                                  : (speed == 1.25
                                        ? 1.5
                                        : (speed == 1.5 ? 2.0 : 1.0));
                              _globalAudioPlayer.setSpeed(newSpeed);
                            },
                            child: Text(
                              "${speed}x",
                              style: const TextStyle(
                                color: Colors.blueGrey,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    return "${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}";
  }

  Future<void> _uploadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null) {
      String pathSnapshot = widget.currentPath;
      for (var file in result.files) {
        if (file.path == null) continue;
        File localFile = File(file.path!);
        String fileName = file.name;
        globalTransferManager.addTask(
          TransferTask(
            name: fileName,
            type: TaskType.upload,
            execute: (task) async {
              task.client = http.Client();
              int totalSize = await localFile.length(),
                  chunkSize = 5 * 1024 * 1024,
                  uploaded = 0;
              var checkRes = await task.client!
                  .post(
                    Uri.parse('${widget.serverUrl}/check_upload'),
                    headers: {
                      "Content-Type": "application/json",
                      "Authorization": "Bearer ${widget.token}",
                    },
                    body: jsonEncode({
                      "path": pathSnapshot,
                      "filename": fileName,
                      "total_size": totalSize,
                    }),
                  )
                  .timeout(const Duration(seconds: 10));

              if (checkRes.statusCode == 200) {
                var data = jsonDecode(checkRes.body);
                if (data['status'] == 'finished') {
                  task.progress = 1.0;
                  return;
                }
                uploaded = data['uploaded'] ?? 0;
              }
              RandomAccessFile raf = await localFile.open(mode: FileMode.read);
              try {
                while (uploaded < totalSize) {
                  if (task.isCanceled) break;
                  raf.setPositionSync(uploaded);
                  int currentChunkSize = (totalSize - uploaded) > chunkSize
                      ? chunkSize
                      : (totalSize - uploaded);
                  List<int> chunk = raf.readSync(currentChunkSize);
                  var request = http.MultipartRequest(
                    'POST',
                    Uri.parse('${widget.serverUrl}/upload_chunk'),
                  );
                  request.headers['Authorization'] = 'Bearer ${widget.token}';
                  request.fields['path'] = pathSnapshot;
                  request.fields['filename'] = fileName;
                  request.fields['offset'] = uploaded.toString();
                  request.fields['total_size'] = totalSize.toString();
                  request.files.add(
                    http.MultipartFile.fromBytes(
                      'file',
                      chunk,
                      filename: fileName,
                    ),
                  );
                  var streamedResponse = await task.client!
                      .send(request)
                      .timeout(const Duration(seconds: 30));

                  if (streamedResponse.statusCode == 200) {
                    uploaded += currentChunkSize;
                    task.progress = uploaded / totalSize;
                    task.statusText =
                        "${(uploaded / 1024 / 1024).toStringAsFixed(1)} / ${(totalSize / 1024 / 1024).toStringAsFixed(1)} MB";
                    globalTransferManager.notifyListeners();
                  } else {
                    throw Exception("网络中断");
                  }
                }
              } finally {
                raf.closeSync();
              }
            },
          ),
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 ${result.files.length} 个文件加入后台上传队列')),
      );
    }
  }

  Future<void> _batchDownload() async {
    int count = _selectedFiles.length;
    for (String name in _selectedFiles) {
      String encodedPath = Uri.encodeComponent(
        "${widget.currentPath.isEmpty ? "" : "${widget.currentPath}/"}$name",
      );
      String downloadUrl =
          "${widget.serverUrl}/download/$encodedPath?token=${widget.token}";
      globalTransferManager.addTask(
        TransferTask(
          name: name,
          type: TaskType.download,
          execute: (task) async {
            task.client = http.Client();
            var request = http.Request('GET', Uri.parse(downloadUrl));
            var streamedResponse = await task.client!.send(request);
            if (streamedResponse.statusCode != 200)
              throw Exception("下载失败: ${streamedResponse.statusCode}");
            int totalBytes = streamedResponse.contentLength ?? 0,
                receivedBytes = 0;
            List<int> bytes = [];
            await for (var chunk in streamedResponse.stream) {
              if (task.isCanceled) return;
              bytes.addAll(chunk);
              receivedBytes += chunk.length;
              if (totalBytes > 0) {
                task.progress = receivedBytes / totalBytes;
                task.statusText =
                    "${(receivedBytes / 1024 / 1024).toStringAsFixed(1)}MB / ${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB";
                globalTransferManager.notifyListeners();
              }
            }
            final tempDir = await getTemporaryDirectory();
            final savePath = '${tempDir.path}/$name';
            await File(savePath).writeAsBytes(bytes);
            if (name.toLowerCase().endsWith('.mp4') ||
                name.toLowerCase().endsWith('.mov'))
              await Gal.putVideo(savePath);
            else if ([
              '.jpg',
              '.png',
              '.jpeg',
              '.gif',
            ].any((e) => name.toLowerCase().endsWith(e)))
              await Gal.putImage(savePath);
          },
        ),
      );
    }
    _exitSelectionMode();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已将 $count 个文件加入后台下载队列')));
  }

  Future<void> _syncGallery() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请授予相册权限')));
      return;
    }
    final List<ConnectivityResult> connectivityResult = await (Connectivity()
        .checkConnectivity());
    if (connectivityResult.contains(ConnectivityResult.mobile) &&
        !connectivityResult.contains(ConnectivityResult.wifi)) {
      bool? allowMobile = await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ 流量警告'),
          content: const Text('未连接 Wi-Fi，确定要继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (allowMobile != true) return;
    }

    globalTransferManager.addTask(
      TransferTask(
        name: "手机相册手动全面备份",
        type: TaskType.sync,
        execute: (task) async {
          task.client = http.Client();
          task.statusText = "正在扫描系统相册...";
          globalTransferManager.notifyListeners();

          List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
            type: RequestType.common,
          );
          if (albums.isEmpty) throw Exception("没有找到相册");
          List<AssetEntity> allAssets = await albums[0].getAssetListRange(
            start: 0,
            end: 100000,
          );
          List<AssetEntity> needSyncAssets = [];

          for (int i = 0; i < allAssets.length; i += 500) {
            if (task.isCanceled) return;
            task.statusText = "比对本地数据 (${i}/${allAssets.length})";
            globalTransferManager.notifyListeners();

            int end = (i + 500 < allAssets.length) ? i + 500 : allAssets.length;
            List<AssetEntity> batch = allAssets.sublist(i, end);
            Set<String> localSyncedIds = await SyncDatabase.getSyncedIds(
              batch.map((e) => e.id).toList(),
            );
            for (var asset in batch) {
              if (!localSyncedIds.contains(asset.id)) needSyncAssets.add(asset);
            }
          }

          if (needSyncAssets.isEmpty) {
            task.statusText = "已是最新，无文件需同步";
            return;
          }

          int total = needSyncAssets.length, processed = 0;

          for (var asset in needSyncAssets) {
            if (task.isCanceled) return;
            processed++;
            File? f = await asset.file;
            if (f == null) continue;

            DateTime date = asset.createDateTime;
            String targetFolder =
                "相册备份/${date.year}年${date.month.toString().padLeft(2, '0')}月/${asset.type == AssetType.video ? "视频" : "图片"}";
            String fileName = f.path.split(Platform.pathSeparator).last;
            int totalSize = await f.length();

            var checkRes = await task.client!
                .post(
                  Uri.parse('${widget.serverUrl}/check_upload'),
                  headers: {
                    "Content-Type": "application/json",
                    "Authorization": "Bearer ${widget.token}",
                  },
                  body: jsonEncode({
                    "path": targetFolder,
                    "filename": fileName,
                    "total_size": totalSize,
                  }),
                )
                .timeout(const Duration(seconds: 10));

            if (checkRes.statusCode == 200 &&
                jsonDecode(checkRes.body)['status'] == 'finished') {
              await SyncDatabase.markSynced(asset.id);
              continue;
            }

            RandomAccessFile raf = await f.open(mode: FileMode.read);
            int uploaded = jsonDecode(checkRes.body)['uploaded'] ?? 0;
            try {
              while (uploaded < totalSize) {
                if (task.isCanceled) break;
                raf.setPositionSync(uploaded);
                int currentChunkSize = (totalSize - uploaded) > 5 * 1024 * 1024
                    ? 5 * 1024 * 1024
                    : (totalSize - uploaded);
                List<int> chunk = raf.readSync(currentChunkSize);

                var request = http.MultipartRequest(
                  'POST',
                  Uri.parse('${widget.serverUrl}/upload_chunk'),
                );
                request.headers['Authorization'] = 'Bearer ${widget.token}';
                request.fields['path'] = targetFolder;
                request.fields['filename'] = fileName;
                request.fields['offset'] = uploaded.toString();
                request.fields['total_size'] = totalSize.toString();
                request.files.add(
                  http.MultipartFile.fromBytes(
                    'file',
                    chunk,
                    filename: fileName,
                  ),
                );

                var response = await task.client!
                    .send(request)
                    .timeout(const Duration(seconds: 30));
                if (response.statusCode == 200) {
                  uploaded += currentChunkSize;
                  task.progress = processed / total;
                  task.statusText = "备份中 ($processed/$total)\n$fileName";
                  globalTransferManager.notifyListeners();
                } else {
                  throw Exception("网络中断");
                }
              }
              if (!task.isCanceled) await SyncDatabase.markSynced(asset.id);
            } finally {
              raf.closeSync();
            }
          }
        },
      ),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已启动相册后台同步')));
  }

  void _copySelected() {
    setState(() {
      _globalClipboardFiles = List.from(_selectedFiles);
      _globalClipboardSourcePath = widget.currentPath;
      _globalIsCutOperation = false;
      _exitSelectionMode();
    });
  }

  void _cutSelected() {
    setState(() {
      _globalClipboardFiles = List.from(_selectedFiles);
      _globalClipboardSourcePath = widget.currentPath;
      _globalIsCutOperation = true;
      _exitSelectionMode();
    });
  }

  void _clearClipboard() {
    setState(() {
      _globalClipboardFiles.clear();
      _globalClipboardSourcePath = "";
    });
  }

  Future<void> _pasteFiles() async {
    if (_globalClipboardFiles.isEmpty) return;
    if (_globalClipboardSourcePath == widget.currentPath) {
      _clearClipboard();
      return;
    }
    setState(() => isLoading = true);
    String endpoint = _globalIsCutOperation ? "/batch_move" : "/batch_copy";
    try {
      final response = await http.post(
        Uri.parse('${widget.serverUrl}$endpoint'),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${widget.token}",
        },
        body: jsonEncode({
          "src_path": _globalClipboardSourcePath,
          "dest_path": widget.currentPath,
          "file_names": _globalClipboardFiles,
        }),
      );
      if (response.statusCode == 200) {
        _clearClipboard();
        fetchFiles();
      } else {
        setState(() => isLoading = false);
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  Future<void> _fetchDiskUsage() async {
    try {
      final response = await http.get(
        Uri.parse('${widget.serverUrl}/disk_usage'),
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (response.statusCode == 200 && mounted)
        setState(() => _diskInfo = jsonDecode(response.body));
    } catch (e) {}
  }

  Future<void> fetchFiles() async {
    try {
      final response = await http.get(
        Uri.parse('${widget.serverUrl}/files?path=${widget.currentPath}'),
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (response.statusCode == 200 && mounted)
        setState(() {
          _allFiles = jsonDecode(utf8.decode(response.bodyBytes));
          isLoading = false;
          _applyFilterAndSort();
        });
      _fetchDiskUsage();
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _applyFilterAndSort() {
    List<dynamic> temp = List.from(_allFiles);
    String query = _searchController.text.toLowerCase();
    if (query.isNotEmpty)
      temp = temp
          .where(
            (file) => file['name'].toString().toLowerCase().contains(query),
          )
          .toList();
    temp.sort((a, b) {
      if (a['is_dir'] != b['is_dir']) return a['is_dir'] ? -1 : 1;
      int result = 0;
      switch (_sortType) {
        case SortType.name:
          result = a['name'].toString().compareTo(b['name'].toString());
          break;
        case SortType.size:
          result = (a['size'] as num).compareTo(b['size'] as num);
          break;
        case SortType.date:
          result = (a['mtime'] as num).compareTo(b['mtime'] as num);
          break;
      }
      return _isAscending ? result : -result;
    });
    setState(() => _displayFiles = temp);
  }

  Widget _getFileIcon(String fileName, {bool isDir = false, double size = 24}) {
    if (isDir) return Icon(Icons.folder, color: Colors.amber, size: size);
    String ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'png', 'jpeg', 'gif', 'bmp'].contains(ext))
      return Icon(Icons.image, color: Colors.purple, size: size);
    if (['mp4', 'mov', 'avi', 'mkv'].contains(ext))
      return Icon(Icons.movie, color: Colors.deepOrange, size: size);
    if (['mp3', 'flac', 'wav', 'm4a', 'aac'].contains(ext))
      return Icon(Icons.music_note, color: Colors.pinkAccent, size: size);
    return Icon(Icons.insert_drive_file, color: Colors.grey, size: size);
  }

  Future<void> _openFile(String fileName) async {
    String encodedPath = Uri.encodeComponent(
      "${widget.currentPath.isEmpty ? "" : "${widget.currentPath}/"}$fileName",
    );
    String downloadUrl =
        "${widget.serverUrl}/download/$encodedPath?token=${widget.token}";
    String lower = fileName.toLowerCase();

    if (lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac')) {
      _playAudio(fileName, downloadUrl);
      return;
    }
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpeg')) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImagePage(url: downloadUrl, token: widget.token),
        ),
      );
      return;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPage(url: downloadUrl, token: widget.token),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('正在下载文件以打开...')));
    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/$fileName';
      final response = await http.get(Uri.parse(downloadUrl));
      if (response.statusCode == 200) {
        await File(localPath).writeAsBytes(response.bodyBytes);
        await OpenFilex.open(localPath);
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开失败: $e')));
    }
  }

  void _toggleSelection(String name) {
    setState(() {
      if (_selectedFiles.contains(name)) {
        _selectedFiles.remove(name);
        if (_selectedFiles.isEmpty) _isSelectionMode = false;
      } else
        _selectedFiles.add(name);
    });
  }

  void _enterSelectionMode(String name) {
    setState(() {
      _isSelectionMode = true;
      _selectedFiles.add(name);
      _isSearching = false;
      _searchController.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedFiles.clear();
    });
  }

  Future<void> _batchDelete() async {
    bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${_selectedFiles.length} 项?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      setState(() => isLoading = true);
      try {
        await http.post(
          Uri.parse('${widget.serverUrl}/batch_delete'),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer ${widget.token}",
          },
          body: jsonEncode({
            "parent_path": widget.currentPath,
            "file_names": _selectedFiles.toList(),
          }),
        );
        _exitSelectionMode();
        fetchFiles();
      } catch (e) {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> _showRenameDialog(String oldName) async {
    final controller = TextEditingController(text: oldName);
    String? newName = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != oldName) {
      setState(() => isLoading = true);
      try {
        await http.post(
          Uri.parse('${widget.serverUrl}/rename'),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer ${widget.token}",
          },
          body: jsonEncode({
            "old_path": widget.currentPath.isEmpty
                ? oldName
                : "${widget.currentPath}/$oldName",
            "new_name": newName,
          }),
        );
        _exitSelectionMode();
        fetchFiles();
      } catch (e) {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> _createNewFolder() async {
    final controller = TextEditingController();
    String? folderName = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (folderName != null && folderName.isNotEmpty) {
      setState(() => isLoading = true);
      try {
        await http.post(
          Uri.parse('${widget.serverUrl}/mkdir'),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer ${widget.token}",
          },
          body: jsonEncode({
            "path": widget.currentPath,
            "folder_name": folderName,
          }),
        );
        fetchFiles();
      } catch (e) {
        setState(() => isLoading = false);
      }
    }
  }

  void _onItemTap(String name, bool isDir) {
    if (_isSelectionMode)
      _toggleSelection(name);
    else if (isDir) {
      setState(() {
        _isSearching = false;
        _searchController.clear();
      });
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FileListPage(
            currentPath: widget.currentPath.isEmpty
                ? name
                : "${widget.currentPath}/$name",
            serverUrl: widget.serverUrl,
            token: widget.token,
          ),
        ),
      );
    } else
      _openFile(name);
  }

  Widget _buildDrawer() {
    double percent = 0;
    String usageText = "计算中...";
    if (_diskInfo != null) {
      int total = _diskInfo!['total'], used = _diskInfo!['used'];
      percent = used / total;
      usageText =
          "已用 ${(used / 1024 / 1024 / 1024).toStringAsFixed(2)}GB / 共 ${(total / 1024 / 1024 / 1024).toStringAsFixed(2)}GB";
    }
    return Drawer(
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            accountName: const Text("我的私有云"),
            accountEmail: Text(widget.serverUrl),
            currentAccountPicture: const CircleAvatar(
              backgroundColor: Colors.white,
              child: Icon(Icons.cloud, size: 40, color: Colors.blue),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.sync, color: Colors.purple),
            title: const Text("手动全面同步相册"),
            onTap: () {
              Navigator.pop(context);
              _syncGallery();
            },
          ),

          SwitchListTile(
            secondary: const Icon(Icons.autorenew, color: Colors.teal),
            title: const Text("夜间充电自动备份"),
            subtitle: const Text("需处于 Wi-Fi 环境"),
            value: _autoSyncEnabled,
            onChanged: (val) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('auto_sync_enabled', val);
              setState(() => _autoSyncEnabled = val);

              if (val) {
                Workmanager().registerPeriodicTask(
                  "autoBackupTask",
                  "autoBackupTask",
                  frequency: const Duration(seconds: 10),
                  constraints: Constraints(networkType: NetworkType.unmetered),
                );
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已开启：连接 Wi-Fi 时将自动备份')),
                  );
              } else {
                Workmanager().cancelByUniqueName("autoBackupTask");
                if (mounted)
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已关闭自动备份')));
              }
            },
          ),

          const Divider(),
          ListTile(
            title: const Text("存储空间"),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: percent,
                  color: percent > 0.9 ? Colors.red : Colors.blue,
                ),
                const SizedBox(height: 5),
                Text(usageText, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const Spacer(),
          // === 🆕 插入远程配置入口 ===
          ListTile(
            leading: const Icon(Icons.settings_remote, color: Colors.blueGrey),
            title: const Text("服务器远程设置"),
            onTap: () async {
              Navigator.pop(context); // 收起侧边栏
              bool? shouldRefresh = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RemoteConfigPage(
                    serverUrl: widget.serverUrl,
                    token: widget.token,
                  ),
                ),
              );
              // 如果仅修改了路径，回来后自动刷新文件列表
              if (shouldRefresh == true) {
                fetchFiles();
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text("退出登录", style: TextStyle(color: Colors.red)),
            onTap: () async {
              await SharedPreferences.getInstance().then(
                (p) => p.remove('server_token'),
              );
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const ConnectPage()),
                (route) => false,
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    if (_isSelectionMode)
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelectionMode,
        ),
        title: Text("已选 ${_selectedFiles.length} 项"),
        backgroundColor: Colors.blueGrey.shade100,
        actions: [
          IconButton(
            icon: const Icon(Icons.content_copy, color: Colors.blue),
            onPressed: _copySelected,
          ),
          IconButton(
            icon: const Icon(Icons.content_cut, color: Colors.orange),
            onPressed: _cutSelected,
          ),
          IconButton(
            icon: const Icon(Icons.download, color: Colors.green),
            onPressed: _batchDownload,
          ),
          if (_selectedFiles.length == 1)
            IconButton(
              icon: const Icon(Icons.edit, color: Colors.blue),
              onPressed: () => _showRenameDialog(_selectedFiles.first),
            ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: _batchDelete,
          ),
        ],
      );
    if (_isSearching)
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            setState(() {
              _isSearching = false;
              _searchController.clear();
              _applyFilterAndSort();
            });
          },
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "搜索文件名...",
            border: InputBorder.none,
          ),
        ),
      );
    return AppBar(
      title: Text(widget.currentPath.isEmpty ? '我的云盘' : widget.currentPath),
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      actions: [
        if (_currentPlayingName.isNotEmpty)
          StreamBuilder<PlayerState>(
            stream: _globalAudioPlayer.playerStateStream,
            builder: (context, snapshot) {
              final playing = snapshot.data?.playing ?? false;
              return IconButton(
                icon: Icon(
                  playing ? Icons.music_note : Icons.music_off,
                  color: Colors.pinkAccent,
                ),
                tooltip: "音乐控制",
                onPressed: _showAudioPlayerSheet,
              );
            },
          ),
        AnimatedBuilder(
          animation: globalTransferManager,
          builder: (context, child) {
            int count = globalTransferManager.activeCount;
            return Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.swap_vert),
                  tooltip: "传输任务",
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TransferPage()),
                  ),
                ),
                if (count > 0)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 16,
                        minHeight: 16,
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.manage_search),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SmartSearchPage(
                serverUrl: widget.serverUrl,
                token: widget.token,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => _isSearching = true),
        ),
        IconButton(
          icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
          onPressed: () => setState(() => _isGridView = !_isGridView),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      drawer: (!_isSelectionMode && !_isSearching) ? _buildDrawer() : null,
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : (_isGridView ? _buildGridView() : _buildListView()),
      floatingActionButton: (_isSelectionMode || _isSearching)
          ? null
          : (_globalClipboardFiles.isNotEmpty
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FloatingActionButton.extended(
                        heroTag: "cancel",
                        onPressed: _clearClipboard,
                        label: const Text("取消"),
                        icon: const Icon(Icons.close),
                        backgroundColor: Colors.red.shade100,
                      ),
                      const SizedBox(width: 10),
                      FloatingActionButton.extended(
                        heroTag: "paste",
                        onPressed: _pasteFiles,
                        label: Text("粘贴 ${_globalClipboardFiles.length} 项"),
                        icon: const Icon(Icons.paste),
                      ),
                    ],
                  )
                : FloatingActionButton(
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      builder: (_) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.create_new_folder),
                              title: const Text('新建文件夹'),
                              onTap: () {
                                Navigator.pop(context);
                                _createNewFolder();
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.upload_file),
                              title: const Text('上传文件'),
                              onTap: () {
                                Navigator.pop(context);
                                _uploadFile();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    child: const Icon(Icons.add),
                  )),
    );
  }

  Widget _buildListView() {
    return RefreshIndicator(
      onRefresh: fetchFiles,
      child: ListView.builder(
        itemCount: _displayFiles.length,
        itemBuilder: (context, index) {
          final file = _displayFiles[index];
          String name = file['name'];
          return ListTile(
            selected: _selectedFiles.contains(name),
            leading: _isSelectionMode
                ? Icon(
                    _selectedFiles.contains(name)
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: _selectedFiles.contains(name)
                        ? Colors.blue
                        : Colors.grey,
                  )
                : _getFileIcon(name, isDir: file['is_dir']),
            title: Text(name),
            subtitle: file['is_dir']
                ? null
                : Text("${(file['size'] / 1024 / 1024).toStringAsFixed(2)} MB"),
            trailing: (!_isSelectionMode && file['is_dir'])
                ? const Icon(Icons.chevron_right)
                : null,
            onTap: () => _onItemTap(name, file['is_dir']),
            onLongPress: () => _isSelectionMode
                ? _toggleSelection(name)
                : _enterSelectionMode(name),
          );
        },
      ),
    );
  }

  Widget _buildGridView() {
    return RefreshIndicator(
      onRefresh: fetchFiles,
      child: GridView.builder(
        padding: const EdgeInsets.all(10),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.8,
        ),
        itemCount: _displayFiles.length,
        itemBuilder: (context, index) {
          final file = _displayFiles[index];
          String name = file['name'];
          String url =
              "${widget.serverUrl}/thumbnail?path=${Uri.encodeComponent("${widget.currentPath.isEmpty ? "" : "${widget.currentPath}/"}$name")}";
          return InkWell(
            onTap: () => _onItemTap(name, file['is_dir']),
            onLongPress: () => _isSelectionMode
                ? _toggleSelection(name)
                : _enterSelectionMode(name),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Card(
                        color: _selectedFiles.contains(name)
                            ? Colors.blue.shade50
                            : null,
                        shape: _selectedFiles.contains(name)
                            ? RoundedRectangleBorder(
                                side: const BorderSide(
                                  color: Colors.blue,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              )
                            : null,
                        clipBehavior: Clip.antiAlias,
                        child: Builder(
                          builder: (context) {
                            if (file['is_dir']) {
                              return const Icon(
                                Icons.folder,
                                size: 50,
                                color: Colors.amber,
                              );
                            }

                            bool isImage = [
                              '.jpg',
                              '.png',
                              '.jpeg',
                              '.gif',
                              '.bmp',
                            ].any((e) => name.toLowerCase().endsWith(e));
                            bool isVideo = [
                              '.mp4',
                              '.mov',
                              '.avi',
                              '.mkv',
                            ].any((e) => name.toLowerCase().endsWith(e));

                            if (isImage || isVideo) {
                              return Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedNetworkImage(
                                    imageUrl: url,
                                    httpHeaders: {
                                      "Authorization": "Bearer ${widget.token}",
                                    }, // 携带鉴权
                                    fit: BoxFit.cover,
                                    memCacheHeight: 200,
                                    placeholder: (c, u) =>
                                        Container(color: Colors.grey[200]),
                                    errorWidget: (c, u, e) => const Icon(
                                      Icons.broken_image,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  if (isVideo)
                                    Container(
                                      color: Colors.black26,
                                      child: const Center(
                                        child: Icon(
                                          Icons.play_circle_outline,
                                          color: Colors.white,
                                          size: 40,
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            } else {
                              return Center(
                                child: _getFileIcon(
                                  name,
                                  isDir: false,
                                  size: 50,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                if (_isSelectionMode)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Icon(
                      _selectedFiles.contains(name)
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: _selectedFiles.contains(name)
                          ? Colors.blue
                          : Colors.grey,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class ImagePage extends StatelessWidget {
  final String url;
  final String token;
  const ImagePage({super.key, required this.url, required this.token});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: CachedNetworkImage(
          imageUrl: url,
          httpHeaders: {"Authorization": "Bearer $token"},
          placeholder: (c, u) => const CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class VideoPage extends StatefulWidget {
  final String url;
  final String token;
  const VideoPage({super.key, required this.url, required this.token});
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late VideoPlayerController _vc;
  ChewieController? _cc;
  @override
  void initState() {
    super.initState();
    _vc = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        setState(
          () => _cc = ChewieController(
            videoPlayerController: _vc,
            autoPlay: true,
            looping: false,
            aspectRatio: _vc.value.aspectRatio,
          ),
        );
      });
  }

  @override
  void dispose() {
    _vc.dispose();
    _cc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: _cc != null
            ? Chewie(controller: _cc!)
            : const CircularProgressIndicator(),
      ),
    );
  }
}

// === 🆕 新增：App 远程服务器配置页面 ===
class RemoteConfigPage extends StatefulWidget {
  final String serverUrl;
  final String token;
  const RemoteConfigPage({
    super.key,
    required this.serverUrl,
    required this.token,
  });

  @override
  State<RemoteConfigPage> createState() => _RemoteConfigPageState();
}

class _RemoteConfigPageState extends State<RemoteConfigPage> {
  final _oldPwdController = TextEditingController();
  final _newUserController = TextEditingController();
  final _newPwdController = TextEditingController();
  final _newPathController = TextEditingController();
  bool _isSubmitting = false;

  Future<void> _submitConfig() async {
    if (_oldPwdController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('必须输入当前密码进行验证')));
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final response = await http.post(
        Uri.parse('${widget.serverUrl}/update_config'),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${widget.token}",
        },
        body: jsonEncode({
          "old_password": _oldPwdController.text.trim(),
          "new_username": _newUserController.text.trim().isNotEmpty
              ? _newUserController.text.trim()
              : null,
          "new_password": _newPwdController.text.trim().isNotEmpty
              ? _newPwdController.text.trim()
              : null,
          "new_root_dir": _newPathController.text.trim().isNotEmpty
              ? _newPathController.text.trim()
              : null,
        }),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('🎉 服务器配置已热更新！')));

          // 如果修改了账号或密码，本地凭证失效，直接踢回登录页
          if (_newUserController.text.isNotEmpty ||
              _newPwdController.text.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('server_token');
            await prefs.remove('server_user');
            await prefs.remove('server_pwd');
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const ConnectPage()),
              (route) => false,
            );
          } else {
            Navigator.pop(context, true); // 仅修改了路径，返回上一页并通知刷新
          }
        }
      } else {
        var err =
            jsonDecode(utf8.decode(response.bodyBytes))['detail'] ?? '更新失败';
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('❌ $err')));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('网络请求失败')));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("服务器远程设置")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "⚠️ 修改立刻生效，服务器无需重启",
              style: TextStyle(
                color: Colors.orange,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _oldPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "当前服务器密码 (必填)",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.security, color: Colors.red),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Divider(),
            ),
            const Text("以下项如不修改请留空：", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 10),
            TextField(
              controller: _newUserController,
              decoration: const InputDecoration(
                labelText: "新用户名",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _newPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "新密码",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _newPathController,
              decoration: const InputDecoration(
                labelText: "新共享目录 (例: E:\\Backup)",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.folder),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: _isSubmitting ? null : _submitConfig,
                icon: _isSubmitting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Icon(Icons.save),
                label: Text(_isSubmitting ? "正在应用..." : "立即应用新配置"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
