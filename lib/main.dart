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

// 音频引擎与后台控制
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

// 全局音频播放器实例，确保跨页面播放不断流
final AudioPlayer _globalAudioPlayer = AudioPlayer();
String _currentPlayingName = "";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 加上 try-catch 防护，即使音频组件在某些机型初始化失败，App 也能正常打开
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.example.cloud_app.audio',
      androidNotificationChannelName: '私有云音乐',
      androidNotificationOngoing: true,
    );
  } catch (e) {
    debugPrint("后台音频初始化提醒: $e");
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

class AssetUploadInfo {
  final AssetEntity asset;
  final File file;
  final String remotePath;
  final String uploadFolder;
  AssetUploadInfo(this.asset, this.file, this.remotePath, this.uploadFolder);
}

// ================== 1. 连接页 ==================
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
      _msg("请输入密码");
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
        var data = jsonDecode(response.body);
        String token = data['token'];

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
        _msg("用户名或密码错误");
      } else {
        _msg("连接异常: ${response.statusCode}");
      }
    } catch (e) {
      _msg("连接失败，请检查IP和网络");
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _msg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

// ================== 2. AI 智能搜图页 ==================
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
        var data = jsonDecode(response.body);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('学习完成！已索引 ${data['indexed']} 张照片')),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('搜索失败: $e')));
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
                      // 缩略图请求，带上 Header 鉴权
                      String url =
                          "${widget.serverUrl}/thumbnail?path=${Uri.encodeComponent(item['path'])}";
                      return InkWell(
                        onTap: () {
                          // 全屏大图使用 URL Token
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

// ================== 3. 文件列表页 ==================
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
      _isUploading = false,
      _isOpeningFile = false,
      _isProcessing = false;
  bool _abortSync = false, _isAborting = false;
  http.Client? _uploadClient;
  AssetEntity? _currentSyncingAsset;
  double _progressValue = 0.0;
  String _progressText = "";
  bool _isSelectionMode = false, _isSearching = false;
  final Set<String> _selectedFiles = {};
  Map<String, dynamic>? _diskInfo;
  final TextEditingController _searchController = TextEditingController();
  SortType _sortType = SortType.name;
  bool _isAscending = true;

  @override
  void initState() {
    super.initState();
    fetchFiles();
    _fetchDiskUsage();
    _searchController.addListener(_applyFilterAndSort);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _uploadClient?.close();
    super.dispose();
  }

  // === 音频播放器相关方法 (已修复防丢 Token + 增加倍速) ===
  Future<void> _playAudio(String fileName, String url) async {
    setState(() {
      _currentPlayingName = fileName;
    });
    try {
      await _globalAudioPlayer.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          // 已经通过在 URL 后面拼接 ?token= 解决了 HTTP Range 被丢请求头的问题
          // 锁屏显示的元数据
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
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法播放音乐: $e')));
    }
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
                // 播放暂停与倍速控件
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 60), // 用于居中占位
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
                              double newSpeed = 1.0;
                              if (speed == 1.0)
                                newSpeed = 1.25;
                              else if (speed == 1.25)
                                newSpeed = 1.5;
                              else if (speed == 1.5)
                                newSpeed = 2.0;
                              else
                                newSpeed = 1.0;
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
    String minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    String seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  // === 核心业务逻辑 ===
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

    WakelockPlus.enable();
    setState(() {
      _isProcessing = true;
      _abortSync = false;
      _isAborting = false;
      _progressValue = 0.0;
      _progressText = "扫描相册...";
      _currentSyncingAsset = null;
    });
    _uploadClient = http.Client();

    try {
      List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
      );
      if (albums.isEmpty) throw Exception("没有找到相册");
      List<AssetEntity> allAssets = await albums[0].getAssetListRange(
        start: 0,
        end: 100000,
      );
      List<AssetEntity> photoAssets = allAssets
          .where((e) => e.type == AssetType.image)
          .toList();
      List<AssetEntity> videoAssets = allAssets
          .where((e) => e.type == AssetType.video)
          .toList();

      int total = allAssets.length,
          processed = 0,
          successCount = 0,
          skippedCount = 0;

      for (int i = 0; i < photoAssets.length; i += 20) {
        if (_abortSync) break;
        int end = (i + 20 < photoAssets.length) ? i + 20 : photoAssets.length;
        List<AssetEntity> batch = photoAssets.sublist(i, end);
        if (batch.isNotEmpty && mounted)
          setState(() => _currentSyncingAsset = batch.first);

        var results = await _processBatch(batch, "同步照片");
        successCount += results['success']!;
        skippedCount += results['skipped']!;
        processed += batch.length;
        if (!_abortSync && mounted)
          setState(() {
            _progressValue = processed / total;
            _progressText = "同步照片中... (${processed}/${total})";
          });
      }

      for (int i = 0; i < videoAssets.length; i++) {
        if (_abortSync) break;
        if (mounted)
          setState(() {
            _currentSyncingAsset = videoAssets[i];
            _progressText = "同步视频中...";
          });
        var results = await _processBatch(
          [videoAssets[i]],
          "同步视频",
          isVideo: true,
        );
        successCount += results['success']!;
        skippedCount += results['skipped']!;
        processed += 1;
        if (!_abortSync && mounted)
          setState(() => _progressValue = processed / total);
      }

      if (mounted && !_abortSync)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步完成: 传 $successCount, 跳过 $skippedCount')),
        );
    } catch (e) {
      if (!_abortSync && mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步出错: $e')));
    } finally {
      _uploadClient?.close();
      _uploadClient = null;
      WakelockPlus.disable();
      if (mounted)
        setState(() {
          _isProcessing = false;
          _isAborting = false;
          _progressText = "";
          _currentSyncingAsset = null;
        });
      fetchFiles();
    }
  }

  void _triggerAbort() {
    setState(() {
      _abortSync = true;
      _isAborting = true;
      _progressText = "正在中止...";
    });
    _uploadClient?.close();
  }

  Future<Map<String, int>> _processBatch(
    List<AssetEntity> batchAssets,
    String stageName, {
    bool isVideo = false,
  }) async {
    if (_abortSync || _uploadClient == null)
      return {'success': 0, 'skipped': 0};
    int success = 0, skipped = 0;
    try {
      List<String> batchIds = batchAssets.map((e) => e.id).toList();
      Set<String> localSyncedIds = await SyncDatabase.getSyncedIds(batchIds);
      List<AssetEntity> needProcessAssets = [];
      for (var asset in batchAssets) {
        if (localSyncedIds.contains(asset.id))
          skipped++;
        else
          needProcessAssets.add(asset);
      }
      if (needProcessAssets.isEmpty) return {'success': 0, 'skipped': skipped};

      List<AssetUploadInfo?> infos = await Future.wait(
        needProcessAssets.map((asset) async {
          File? f = await asset.file;
          if (f == null) return null;
          DateTime date = asset.createDateTime;
          String monthFolder =
              "${date.year}年${date.month.toString().padLeft(2, '0')}月";
          String typeFolder = (asset.type == AssetType.video) ? "视频" : "图片";
          String targetFolder = "相册备份/$monthFolder/$typeFolder";
          String fileName = f.path.split(Platform.pathSeparator).last;
          return AssetUploadInfo(
            asset,
            f,
            "$targetFolder/$fileName",
            targetFolder,
          );
        }),
      );

      List<AssetUploadInfo> validInfos = infos
          .whereType<AssetUploadInfo>()
          .toList();
      if (validInfos.isEmpty) return {'success': 0, 'skipped': skipped};

      var res = await _uploadClient!
          .post(
            Uri.parse('${widget.serverUrl}/batch_check_exists'),
            headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer ${widget.token}",
            },
            body: jsonEncode({
              "paths": validInfos.map((e) => e.remotePath).toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));

      List<bool> existsList = (res.statusCode == 200)
          ? List<bool>.from(jsonDecode(res.body)['results'])
          : List.filled(validInfos.length, false);
      List<AssetUploadInfo> toUpload = [];

      for (int k = 0; k < validInfos.length; k++) {
        if (k < existsList.length && existsList[k]) {
          skipped++;
          await SyncDatabase.markSynced(validInfos[k].asset.id);
        } else
          toUpload.add(validInfos[k]);
      }

      if (_abortSync) return {'success': success, 'skipped': skipped};

      if (toUpload.isNotEmpty) {
        if (isVideo) {
          for (var info in toUpload) {
            if (_abortSync) break;
            if (await _uploadSingleFile(info, isVideo: true)) {
              success++;
              await SyncDatabase.markSynced(info.asset.id);
            }
          }
        } else {
          List<bool> results = await Future.wait(
            toUpload.map((info) => _uploadSingleFile(info, isVideo: false)),
          );
          for (int i = 0; i < results.length; i++) {
            if (results[i]) {
              success++;
              await SyncDatabase.markSynced(toUpload[i].asset.id);
            }
          }
        }
      }
    } catch (e) {}
    return {'success': success, 'skipped': skipped};
  }

  Future<bool> _uploadSingleFile(
    AssetUploadInfo info, {
    required bool isVideo,
  }) async {
    if (_uploadClient == null) return false;
    int totalSize = await info.file.length(),
        chunkSize = 5 * 1024 * 1024,
        uploaded = 0;
    String fileName = info.file.path.split(Platform.pathSeparator).last;

    try {
      var checkRes = await _uploadClient!
          .post(
            Uri.parse('${widget.serverUrl}/check_upload'),
            headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer ${widget.token}",
            },
            body: jsonEncode({
              "path": info.uploadFolder,
              "filename": fileName,
              "total_size": totalSize,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (checkRes.statusCode == 200) {
        var data = jsonDecode(checkRes.body);
        if (data['status'] == 'finished') return true;
        uploaded = data['uploaded'] ?? 0;
      }
    } catch (e) {
      uploaded = 0;
    }

    RandomAccessFile raf = await info.file.open(mode: FileMode.read);
    try {
      while (uploaded < totalSize) {
        if (_abortSync) {
          raf.closeSync();
          return false;
        }
        raf.setPositionSync(uploaded);
        int remain = totalSize - uploaded;
        int currentChunkSize = remain > chunkSize ? chunkSize : remain;
        List<int> chunk = raf.readSync(currentChunkSize);

        var request = http.MultipartRequest(
          'POST',
          Uri.parse('${widget.serverUrl}/upload_chunk'),
        );
        request.headers['Authorization'] = 'Bearer ${widget.token}';
        request.fields['path'] = info.uploadFolder;
        request.fields['filename'] = fileName;
        request.fields['offset'] = uploaded.toString();
        request.fields['total_size'] = totalSize.toString();
        request.files.add(
          http.MultipartFile.fromBytes('file', chunk, filename: fileName),
        );

        var streamedResponse = await _uploadClient!
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (streamedResponse.statusCode == 200) {
          var data = jsonDecode(await streamedResponse.stream.bytesToString());
          if (data['status'] == 'finished') break;
          uploaded += currentChunkSize;
          if (isVideo && mounted && !_isAborting)
            setState(() {
              _progressValue = uploaded / totalSize;
              _progressText =
                  "大视频同步中... ${(uploaded / 1024 / 1024).toStringAsFixed(1)}MB";
            });
        } else {
          raf.closeSync();
          return false;
        }
      }
    } catch (e) {
      raf.closeSync();
      return false;
    }
    raf.closeSync();
    return true;
  }

  Future<void> _uploadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null) {
      setState(() {
        _isProcessing = true;
        _progressValue = 0.0;
        _progressText = "准备上传...";
      });
      _uploadClient = http.Client();
      int successCount = 0;
      try {
        for (int i = 0; i < result.files.length; i++) {
          if (result.files[i].path == null) continue;
          File localFile = File(result.files[i].path!);
          String fileName = result.files[i].name;
          int totalSize = await localFile.length(),
              chunkSize = 5 * 1024 * 1024,
              uploaded = 0;

          try {
            var checkRes = await _uploadClient!
                .post(
                  Uri.parse('${widget.serverUrl}/check_upload'),
                  headers: {
                    "Content-Type": "application/json",
                    "Authorization": "Bearer ${widget.token}",
                  },
                  body: jsonEncode({
                    "path": widget.currentPath,
                    "filename": fileName,
                    "total_size": totalSize,
                  }),
                )
                .timeout(const Duration(seconds: 10));
            if (checkRes.statusCode == 200) {
              var data = jsonDecode(checkRes.body);
              if (data['status'] == 'finished') {
                successCount++;
                continue;
              }
              uploaded = data['uploaded'] ?? 0;
            }
          } catch (e) {}

          RandomAccessFile raf = await localFile.open(mode: FileMode.read);
          bool isFileSuccess = true;
          try {
            while (uploaded < totalSize) {
              if (_abortSync) break;
              raf.setPositionSync(uploaded);
              int remain = totalSize - uploaded;
              int currentChunkSize = remain > chunkSize ? chunkSize : remain;
              List<int> chunk = raf.readSync(currentChunkSize);

              var request = http.MultipartRequest(
                'POST',
                Uri.parse('${widget.serverUrl}/upload_chunk'),
              );
              request.headers['Authorization'] = 'Bearer ${widget.token}';
              request.fields['path'] = widget.currentPath;
              request.fields['filename'] = fileName;
              request.fields['offset'] = uploaded.toString();
              request.fields['total_size'] = totalSize.toString();
              request.files.add(
                http.MultipartFile.fromBytes('file', chunk, filename: fileName),
              );

              var streamedResponse = await _uploadClient!
                  .send(request)
                  .timeout(const Duration(seconds: 30));
              if (streamedResponse.statusCode == 200) {
                uploaded += currentChunkSize;
                if (mounted)
                  setState(() {
                    _progressValue = uploaded / totalSize;
                    _progressText =
                        "上传文件 (${i + 1}/${result.files.length})\n$fileName\n(${(uploaded / 1024 / 1024).toStringAsFixed(1)}MB)";
                  });
              } else {
                isFileSuccess = false;
                break;
              }
            }
          } catch (e) {
            isFileSuccess = false;
          } finally {
            raf.closeSync();
          }
          if (isFileSuccess) successCount++;
        }
        fetchFiles();
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('成功上传 $successCount 个文件')));
      } catch (e) {
      } finally {
        _uploadClient?.close();
        _uploadClient = null;
        if (mounted)
          setState(() {
            _isProcessing = false;
            _progressValue = 0.0;
            _progressText = "";
          });
      }
    }
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
    // 🆕 URL 拼接 token 兼容断流和播放器丢头问题
    String downloadUrl =
        "${widget.serverUrl}/download/$encodedPath?token=${widget.token}";
    String lower = fileName.toLowerCase();

    // 拦截音频
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac')) {
      _playAudio(fileName, downloadUrl);
      return;
    }

    // 拦截图频
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpeg')) {
      // 图片直接传带了 token 的 url 过去就行
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

    // 其他文件走下载后本地打开逻辑
    setState(() => _isOpeningFile = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/$fileName';
      final response = await http.get(Uri.parse(downloadUrl));
      if (response.statusCode == 200) {
        await File(localPath).writeAsBytes(response.bodyBytes);
        await OpenFilex.open(localPath);
      }
    } catch (e) {
    } finally {
      setState(() => _isOpeningFile = false);
    }
  }

  Future<void> _batchDownload() async {
    setState(() {
      _isProcessing = true;
      _progressValue = 0.0;
      _progressText = "准备下载...";
    });
    int successCount = 0,
        totalFiles = _selectedFiles.length,
        processedCount = 0;
    for (String name in _selectedFiles) {
      try {
        String encodedPath = Uri.encodeComponent(
          "${widget.currentPath.isEmpty ? "" : "${widget.currentPath}/"}$name",
        );
        var response = await http.get(
          Uri.parse(
            "${widget.serverUrl}/download/$encodedPath?token=${widget.token}",
          ),
        );
        if (response.statusCode == 200) {
          final tempDir = await getTemporaryDirectory();
          final savePath = '${tempDir.path}/$name';
          await File(savePath).writeAsBytes(response.bodyBytes);
          if (name.toLowerCase().endsWith('.mp4') ||
              name.toLowerCase().endsWith('.mov'))
            await Gal.putVideo(savePath);
          else
            await Gal.putImage(savePath);
          successCount++;
        }
      } catch (e) {}
      processedCount++;
      setState(() {
        _progressValue = processedCount / totalFiles;
        _progressText = "正在下载 $processedCount / $totalFiles";
      });
    }
    setState(() {
      _isProcessing = false;
      _progressValue = 0.0;
      _progressText = "";
    });
    _exitSelectionMode();
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
            title: const Text("同步手机相册"),
            onTap: () {
              Navigator.pop(context);
              _syncGallery();
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
      title: Text(
        _isUploading
            ? "处理中..."
            : (_isOpeningFile
                  ? "打开中..."
                  : (widget.currentPath.isEmpty ? '我的云盘' : widget.currentPath)),
      ),
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      actions: [
        // 全局正在播放指示器（当有音乐加载时显示小音符）
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
      body: Stack(
        children: [
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : (_isGridView ? _buildGridView() : _buildListView()),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        Text(_progressText, textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _isAborting ? null : _triggerAbort,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: Text(_isAborting ? "中止中..." : "停止"),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
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
                    onPressed: _isUploading
                        ? null
                        : () => showModalBottomSheet(
                            context: context,
                            builder: (_) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(
                                      Icons.create_new_folder,
                                    ),
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
                        child: file['is_dir']
                            ? const Icon(
                                Icons.folder,
                                size: 50,
                                color: Colors.amber,
                              )
                            : ([
                                    '.jpg',
                                    '.png',
                                    '.jpeg',
                                  ].any((e) => name.toLowerCase().endsWith(e))
                                  ? CachedNetworkImage(
                                      imageUrl: url,
                                      httpHeaders: {
                                        "Authorization":
                                            "Bearer ${widget.token}",
                                      },
                                      fit: BoxFit.cover,
                                      placeholder: (c, u) =>
                                          Container(color: Colors.grey[200]),
                                      errorWidget: (c, u, e) =>
                                          const Icon(Icons.broken_image),
                                    )
                                  : Center(
                                      child: _getFileIcon(
                                        name,
                                        isDir: false,
                                        size: 50,
                                      ),
                                    )),
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
      // 注意：这里由于我们前面重构了 _openFile，传过来的 url 已经自带 ?token= 尾巴了，但 CachedNetworkImage 依然用 header 传也可，双重保险
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
    // 视频因为要拖动进度条，底层播放器会丢头，所以这里移除了 httpHeaders，直接通过带 ?token= 的 URL 播放
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
