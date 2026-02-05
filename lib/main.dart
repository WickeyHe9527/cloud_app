import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // 必须引用，否则 Uint8List 报错

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

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '私有云盘 AI版',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const ConnectPage(),
    );
  }
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
        await prefs.setString('server_ip', ip);
        await prefs.setString('server_user', user);
        await prefs.setString('server_pwd', pwd);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => FileListPage(currentPath: "", serverUrl: ip),
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
        } else {
          _msg("二维码格式不正确");
        }
      } catch (e) {
        _msg("无法解析二维码: $e");
      }
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
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
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
  const SmartSearchPage({super.key, required this.serverUrl});

  @override
  State<SmartSearchPage> createState() => _SmartSearchPageState();
}

class _SmartSearchPageState extends State<SmartSearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<dynamic> _results = [];
  bool _isSearching = false;
  bool _isIndexing = false;

  Future<void> _startIndexing() async {
    setState(() => _isIndexing = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('AI 正在学习你的照片，请关注服务端控制台进度...')));
    try {
      final response = await http
          .get(Uri.parse('${widget.serverUrl}/index_photos'))
          .timeout(const Duration(minutes: 30));
      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('学习完成！已索引 ${data['indexed']} 张照片')),
          );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('索引指令已发送 (后台运行中)')));
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
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"query": _controller.text, "limit": 50}),
      );
      if (response.statusCode == 200) {
        setState(() {
          _results = jsonDecode(utf8.decode(response.bodyBytes))['results'];
        });
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
                  tooltip: "更新索引",
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
                hintText: "试试搜索: 猫、海边、生日蛋糕...",
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
                      "输入关键词，AI 帮你找照片\n(新上传照片请点右上角刷新)",
                      textAlign: TextAlign.center,
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
                                    "${widget.serverUrl}/download/${Uri.encodeComponent(item['path'])}",
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

// ================== 3. 文件列表页 (修复版) ==================
enum SortType { name, size, date }

List<String> _globalClipboardFiles = [];
String _globalClipboardSourcePath = "";
bool _globalIsCutOperation = false;

class AssetUploadInfo {
  final AssetEntity asset;
  final File file;
  final String remotePath;
  final String uploadFolder;
  AssetUploadInfo(this.asset, this.file, this.remotePath, this.uploadFolder);
}

class FileListPage extends StatefulWidget {
  final String currentPath;
  final String serverUrl;
  const FileListPage({
    super.key,
    required this.currentPath,
    required this.serverUrl,
  });

  @override
  State<FileListPage> createState() => _FileListPageState();
}

class _FileListPageState extends State<FileListPage> {
  List<dynamic> _allFiles = [];
  List<dynamic> _displayFiles = [];
  bool isLoading = true;
  bool _isGridView = false;

  bool _isUploading = false;
  bool _isOpeningFile = false;
  bool _isProcessing = false;

  bool _abortSync = false;
  bool _isAborting = false;
  http.Client? _uploadClient;

  AssetEntity? _currentSyncingAsset;

  double _progressValue = 0.0;
  String _progressText = "";
  bool _isSelectionMode = false;
  final Set<String> _selectedFiles = {};
  Map<String, dynamic>? _diskInfo;
  bool _isSearching = false;
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

  // === 核心同步逻辑 ===
  Future<void> _syncGallery() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请授予相册访问权限')));
      return;
    }

    // Wi-Fi 流量检测
    final List<ConnectivityResult> connectivityResult = await (Connectivity()
        .checkConnectivity());
    bool isMobile = connectivityResult.contains(ConnectivityResult.mobile);
    bool hasWifi = connectivityResult.contains(ConnectivityResult.wifi);

    if (isMobile && !hasWifi) {
      bool? allowMobile = await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ 流量警告'),
          content: const Text('当前未连接 Wi-Fi，同步可能会消耗大量流量。\n\n确定要继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消同步'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('使用流量继续', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (allowMobile != true) return;
    }

    bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('准备同步'),
        content: const Text(
          '系统将自动比对云端文件，仅上传新内容。\n\n你可以随时点击“停止”按钮暂停，下次点击同步可自动续传。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    WakelockPlus.enable();

    setState(() {
      _isProcessing = true;
      _abortSync = false;
      _isAborting = false;
      _progressValue = 0.0;
      _progressText = "正在扫描本地相册...";
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

      int total = allAssets.length;
      int processed = 0;
      int successCount = 0;
      int skippedCount = 0;

      // 阶段一：照片
      int photoBatchSize = 20;
      for (int i = 0; i < photoAssets.length; i += photoBatchSize) {
        if (_abortSync) break;

        int end = (i + photoBatchSize < photoAssets.length)
            ? i + photoBatchSize
            : photoAssets.length;
        List<AssetEntity> batch = photoAssets.sublist(i, end);

        if (batch.isNotEmpty && mounted) {
          setState(() => _currentSyncingAsset = batch.first);
        }

        var results = await _processBatch(batch, "同步照片");
        successCount += results['success']!;
        skippedCount += results['skipped']!;
        processed += batch.length;

        if (!_abortSync && mounted) {
          setState(() {
            _progressValue = processed / total;
            _progressText =
                "同步照片中... (${processed}/${total})\n已传: $successCount  跳过: $skippedCount";
          });
        }
      }

      // 阶段二：视频
      for (int i = 0; i < videoAssets.length; i++) {
        if (_abortSync) break;

        List<AssetEntity> batch = [videoAssets[i]];

        if (mounted) {
          setState(() {
            _currentSyncingAsset = videoAssets[i];
            _progressText = "同步视频中 (大文件请等待)...\n进度: ${processed + 1} / $total";
          });
        }

        var results = await _processBatch(batch, "同步视频", isVideo: true);
        successCount += results['success']!;
        skippedCount += results['skipped']!;
        processed += 1;

        if (!_abortSync && mounted) {
          setState(() {
            _progressValue = processed / total;
          });
        }
      }

      if (mounted && !_abortSync) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步完成: 上传 $successCount, 跳过 $skippedCount')),
        );
      }
    } catch (e) {
      if (!_abortSync && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步出错: $e')));
      }
    } finally {
      _uploadClient?.close();
      _uploadClient = null;
      WakelockPlus.disable();

      if (mounted) {
        setState(() {
          _isProcessing = false;
          _isAborting = false;
          _progressValue = 0.0;
          _progressText = "";
          _currentSyncingAsset = null;
        });
      }
      fetchFiles();

      if (_abortSync && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已手动中止同步')));
      }
    }
  }

  void _triggerAbort() {
    setState(() {
      _abortSync = true;
      _isAborting = true;
      _progressText = "正在中止任务，请稍候...";
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

    int success = 0;
    int skipped = 0;

    try {
      List<AssetUploadInfo?> infos = await Future.wait(
        batchAssets.map((asset) async {
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
      if (validInfos.isEmpty) return {'success': 0, 'skipped': 0};

      List<String> checkPaths = validInfos.map((e) => e.remotePath).toList();
      List<bool> existsList = [];

      var res = await _uploadClient!
          .post(
            Uri.parse('${widget.serverUrl}/batch_check_exists'),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"paths": checkPaths}),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        existsList = List<bool>.from(jsonDecode(res.body)['results']);
      } else {
        existsList = List.filled(validInfos.length, false);
      }

      List<AssetUploadInfo> toUpload = [];
      for (int k = 0; k < validInfos.length; k++) {
        if (k < existsList.length && existsList[k]) {
          skipped++;
        } else {
          toUpload.add(validInfos[k]);
        }
      }

      if (_abortSync) return {'success': success, 'skipped': skipped};

      if (toUpload.isNotEmpty) {
        if (isVideo) {
          for (var info in toUpload) {
            if (_abortSync) break;
            bool res = await _uploadSingleFile(info, isVideo: true);
            if (res) success++;
          }
        } else {
          List<bool> results = await Future.wait(
            toUpload.map((info) => _uploadSingleFile(info, isVideo: false)),
          );
          for (var res in results) if (res) success++;
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
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('${widget.serverUrl}/upload'),
      );
      request.fields['path'] = info.uploadFolder;
      request.files.add(
        await http.MultipartFile.fromPath('files', info.file.path),
      );

      var streamedResponse = await _uploadClient!
          .send(request)
          .timeout(
            Duration(seconds: isVideo ? 600 : 30),
            onTimeout: () {
              throw Exception("Timeout");
            },
          );
      var response = await http.Response.fromStream(streamedResponse);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // ... (其余功能代码) ...
  void _copySelected() {
    setState(() {
      _globalClipboardFiles = List.from(_selectedFiles);
      _globalClipboardSourcePath = widget.currentPath;
      _globalIsCutOperation = false;
      _exitSelectionMode();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_globalClipboardFiles.length} 项')),
    );
  }

  void _cutSelected() {
    setState(() {
      _globalClipboardFiles = List.from(_selectedFiles);
      _globalClipboardSourcePath = widget.currentPath;
      _globalIsCutOperation = true;
      _exitSelectionMode();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已剪切 ${_globalClipboardFiles.length} 项')),
    );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('源目录和目标目录相同')));
      _clearClipboard();
      return;
    }
    setState(() => isLoading = true);
    String endpoint = _globalIsCutOperation ? "/batch_move" : "/batch_copy";
    try {
      final response = await http.post(
        Uri.parse('${widget.serverUrl}$endpoint'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "src_path": _globalClipboardSourcePath,
          "dest_path": widget.currentPath,
          "file_names": _globalClipboardFiles,
        }),
      );
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_globalIsCutOperation ? '移动成功' : '复制成功')),
        );
        _clearClipboard();
        fetchFiles();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作失败')));
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
      );
      if (response.statusCode == 200)
        if (mounted) setState(() => _diskInfo = jsonDecode(response.body));
    } catch (e) {
      print(e);
    }
  }

  Future<void> fetchFiles() async {
    try {
      final url = Uri.parse(
        '${widget.serverUrl}/files?path=${widget.currentPath}',
      );
      final response = await http.get(url);
      if (response.statusCode == 200)
        if (mounted)
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
    if (['mp3', 'wav', 'flac', 'aac'].contains(ext))
      return Icon(Icons.music_note, color: Colors.pink, size: size);
    if (ext == 'pdf')
      return Icon(Icons.picture_as_pdf, color: Colors.red, size: size);
    if (['doc', 'docx'].contains(ext))
      return Icon(Icons.description, color: Colors.blue, size: size);
    if (['xls', 'xlsx'].contains(ext))
      return Icon(Icons.table_chart, color: Colors.green, size: size);
    if (['ppt', 'pptx'].contains(ext))
      return Icon(Icons.slideshow, color: Colors.orange, size: size);
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext))
      return Icon(Icons.folder_zip, color: Colors.brown, size: size);
    if ([
      'py',
      'dart',
      'c',
      'cpp',
      'js',
      'html',
      'css',
      'json',
      'xml',
    ].contains(ext))
      return Icon(Icons.code, color: Colors.blueGrey, size: size);
    if (['txt', 'md'].contains(ext))
      return Icon(Icons.text_snippet, color: Colors.grey, size: size);
    return Icon(Icons.insert_drive_file, color: Colors.grey, size: size);
  }

  Future<void> _openFile(String fileName) async {
    String pathPrefix = widget.currentPath.isEmpty
        ? ""
        : "${widget.currentPath}/";
    String encodedPath = Uri.encodeComponent("$pathPrefix$fileName");
    String downloadUrl = "${widget.serverUrl}/download/$encodedPath";
    String lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpeg')) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ImagePage(url: downloadUrl)),
      );
      return;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VideoPage(url: downloadUrl)),
      );
      return;
    }
    setState(() => _isOpeningFile = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/$fileName';
      final file = File(localPath);
      final response = await http.get(Uri.parse(downloadUrl));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        await OpenFilex.open(localPath);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开失败: $e')));
    } finally {
      setState(() => _isOpeningFile = false);
    }
  }

  Future<void> _disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server_pwd');
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const ConnectPage()),
      (route) => false,
    );
  }

  Future<String?> _getSavePath(String fileName) async {
    Directory? directory;
    try {
      if (Platform.isAndroid) {
        directory = Directory('/storage/emulated/0/Download');
        if (!await directory.exists())
          directory = await getExternalStorageDirectory();
      } else {
        directory = await getApplicationDocumentsDirectory();
      }
      return '${directory?.path}/$fileName';
    } catch (e) {
      return null;
    }
  }

  Future<bool> _downloadFileInternal(String fileName) async {
    try {
      String pathPrefix = widget.currentPath.isEmpty
          ? ""
          : "${widget.currentPath}/";
      String encodedPath = Uri.encodeComponent("$pathPrefix$fileName");
      String url = "${widget.serverUrl}/download/$encodedPath";
      var response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        String lower = fileName.toLowerCase();
        bool isMedia = [
          '.jpg',
          '.png',
          '.jpeg',
          '.mp4',
          '.mov',
          '.mkv',
        ].any((ext) => lower.endsWith(ext));
        if (isMedia) {
          final tempDir = await getTemporaryDirectory();
          final savePath = '${tempDir.path}/$fileName';
          File file = File(savePath);
          await file.writeAsBytes(response.bodyBytes);
          if (lower.endsWith('.mp4') || lower.endsWith('.mov'))
            await Gal.putVideo(savePath);
          else
            await Gal.putImage(savePath);
          if (await file.exists()) await file.delete();
        } else {
          String? savePath = await _getSavePath(fileName);
          if (savePath != null) {
            File file = File(savePath);
            int num = 1;
            while (await file.exists()) {
              String nameWithoutExt = fileName.substring(
                0,
                fileName.lastIndexOf('.'),
              );
              String ext = fileName.substring(fileName.lastIndexOf('.'));
              file = File('${file.parent.path}/${nameWithoutExt}_$num$ext');
              num++;
            }
            await file.writeAsBytes(response.bodyBytes);
          } else
            return false;
        }
        return true;
      }
    } catch (e) {
      print(e);
    }
    return false;
  }

  Future<void> _batchDownload() async {
    if (!await Permission.storage.request().isGranted) {
      if (Platform.isAndroid && await Permission.photos.request().isDenied)
        return;
    }
    setState(() {
      _isProcessing = true;
      _progressValue = 0.0;
      _progressText = "准备下载...";
    });
    int successCount = 0;
    int totalFiles = _selectedFiles.length;
    int processedCount = 0;
    for (String name in _selectedFiles) {
      bool success = await _downloadFileInternal(name);
      if (success) successCount++;
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
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载完成: 成功 $successCount / $totalFiles')),
      );
  }

  void _toggleSelection(String name) {
    setState(() {
      if (_selectedFiles.contains(name)) {
        _selectedFiles.remove(name);
        if (_selectedFiles.isEmpty) _isSelectionMode = false;
      } else {
        _selectedFiles.add(name);
      }
    });
  }

  void _enterSelectionMode(String name) {
    setState(() {
      _isSelectionMode = true;
      _selectedFiles.add(name);
      if (_isSearching) {
        _isSearching = false;
        _searchController.clear();
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedFiles.clear();
    });
  }

  void _toggleSelectAll() {
    setState(() {
      bool isAllSelected =
          _displayFiles.isNotEmpty &&
          _selectedFiles.length == _displayFiles.length;
      if (isAllSelected) {
        _selectedFiles.clear();
        _isSelectionMode = false;
      } else {
        _selectedFiles.clear();
        for (var file in _displayFiles) _selectedFiles.add(file['name']);
      }
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
          headers: {"Content-Type": "application/json"},
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
          headers: {"Content-Type": "application/json"},
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
          headers: {"Content-Type": "application/json"},
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

  Future<void> _uploadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null) {
      setState(() {
        _isProcessing = true;
        _progressValue = 0.0;
        _progressText = "正在上传...";
      });
      try {
        var request = http.MultipartRequest(
          'POST',
          Uri.parse('${widget.serverUrl}/upload'),
        );
        request.fields['path'] = widget.currentPath;
        for (var file in result.files)
          if (file.path != null)
            request.files.add(
              await http.MultipartFile.fromPath('files', file.path!),
            );
        var response = await request.send();
        if (response.statusCode == 200) {
          fetchFiles();
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('上传完成')));
        }
      } catch (e) {
        print(e);
      } finally {
        setState(() {
          _isProcessing = false;
          _progressValue = 0.0;
          _progressText = "";
        });
      }
    }
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.create_new_folder,
                  color: Colors.amber,
                ),
                title: const Text('新建文件夹'),
                onTap: () {
                  Navigator.pop(context);
                  _createNewFolder();
                },
              ),
              ListTile(
                leading: const Icon(Icons.upload_file, color: Colors.blue),
                title: const Text('上传文件'),
                onTap: () {
                  Navigator.pop(context);
                  _uploadFile();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _onItemTap(String name, bool isDir) {
    if (_isSelectionMode)
      _toggleSelection(name);
    else {
      if (isDir) {
        setState(() {
          _isSearching = false;
          _searchController.clear();
        });
        String newPath = widget.currentPath.isEmpty
            ? name
            : "${widget.currentPath}/$name";
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                FileListPage(currentPath: newPath, serverUrl: widget.serverUrl),
          ),
        );
      } else
        _openFile(name);
    }
  }

  void _onItemLongPress(String name) {
    if (!_isSelectionMode)
      _enterSelectionMode(name);
    else
      _toggleSelection(name);
  }

  Widget _buildDrawer() {
    double percent = 0;
    String usageText = "计算中...";
    if (_diskInfo != null) {
      int total = _diskInfo!['total'];
      int used = _diskInfo!['used'];
      percent = used / total;
      usageText = "已用 ${_formatSize(used)} / 共 ${_formatSize(total)}";
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
            decoration: const BoxDecoration(color: Colors.blue),
          ),
          ListTile(
            leading: const Icon(Icons.sync, color: Colors.purple),
            title: const Text("同步手机相册"),
            subtitle: const Text("按日期自动备份到云端"),
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
                  backgroundColor: Colors.grey[300],
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
            onTap: _disconnect,
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    if (_isSelectionMode) {
      bool isAllSelected =
          _displayFiles.isNotEmpty &&
          _selectedFiles.length == _displayFiles.length;
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelectionMode,
        ),
        title: Text("已选 ${_selectedFiles.length} 项"),
        backgroundColor: Colors.blueGrey.shade100,
        actions: [
          IconButton(
            icon: Icon(isAllSelected ? Icons.deselect : Icons.select_all),
            onPressed: _toggleSelectAll,
          ),
          IconButton(
            icon: const Icon(Icons.content_copy, color: Colors.blue),
            onPressed: _copySelected,
            tooltip: "复制",
          ),
          IconButton(
            icon: const Icon(Icons.content_cut, color: Colors.orange),
            onPressed: _cutSelected,
            tooltip: "剪切",
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
    }
    if (_isSearching) {
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
          style: const TextStyle(fontSize: 18),
        ),
      );
    }
    // 🆕 AppBar: 添加 AI 搜索入口
    return AppBar(
      title: _isUploading
          ? const Text("处理中...")
          : (_isOpeningFile
                ? const Text("正在打开...")
                : Text(
                    widget.currentPath.isEmpty ? '我的云盘' : widget.currentPath,
                  )),
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      actions: [
        // 🔍 搜索按钮
        IconButton(
          icon: const Icon(Icons.manage_search),
          tooltip: "AI 智能搜图",
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SmartSearchPage(serverUrl: widget.serverUrl),
              ),
            );
          },
        ),
        // 原有按钮...
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => _isSearching = true),
        ),
        PopupMenuButton<SortType>(
          icon: const Icon(Icons.sort),
          onSelected: (SortType result) {
            if (_sortType == result)
              setState(() => _isAscending = !_isAscending);
            else
              setState(() {
                _sortType = result;
                _isAscending = true;
              });
            _applyFilterAndSort();
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<SortType>>[
            PopupMenuItem<SortType>(
              value: SortType.name,
              child: Row(
                children: [
                  const Text('按名称'),
                  if (_sortType == SortType.name)
                    Icon(
                      _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                    ),
                ],
              ),
            ),
            PopupMenuItem<SortType>(
              value: SortType.size,
              child: Row(
                children: [
                  const Text('按大小'),
                  if (_sortType == SortType.size)
                    Icon(
                      _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                    ),
                ],
              ),
            ),
            PopupMenuItem<SortType>(
              value: SortType.date,
              child: Row(
                children: [
                  const Text('按时间'),
                  if (_sortType == SortType.date)
                    Icon(
                      _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                    ),
                ],
              ),
            ),
          ],
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
                  elevation: 10,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 🖼️ 实时缩略图 (修复版: 使用 FutureBuilder)
                        if (_currentSyncingAsset != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 20),
                            height: 120,
                            width: 120,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.2),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                              color: Colors.grey[800],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  FutureBuilder<Uint8List?>(
                                    future: _currentSyncingAsset!
                                        .thumbnailDataWithSize(
                                          const ThumbnailSize.square(200),
                                        ),
                                    builder: (context, snapshot) {
                                      if (snapshot.connectionState ==
                                              ConnectionState.done &&
                                          snapshot.data != null) {
                                        return Image.memory(
                                          snapshot.data!,
                                          fit: BoxFit.cover,
                                          gaplessPlayback: true,
                                        );
                                      }
                                      return const Center(
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      );
                                    },
                                  ),
                                  if (_currentSyncingAsset!.type ==
                                      AssetType.video)
                                    const Center(
                                      child: Icon(
                                        Icons.play_circle_fill,
                                        color: Colors.white70,
                                        size: 40,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),

                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        Text(
                          _progressText,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: _isAborting ? null : _triggerAbort,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          icon: const Icon(Icons.stop),
                          label: Text(_isAborting ? "正在中止..." : "停止同步"),
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
                    onPressed: _isUploading ? null : _showAddMenu,
                    child: const Icon(Icons.add),
                  )),
    );
  }

  // ✅ 补全的 _buildListView
  Widget _buildListView() {
    return RefreshIndicator(
      onRefresh: fetchFiles,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _displayFiles.length,
        itemBuilder: (context, index) {
          final file = _displayFiles[index];
          String name = file['name'];
          return ListTile(
            selected: _selectedFiles.contains(name),
            selectedTileColor: Colors.blue.withOpacity(0.1),
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
                : Text(
                    "${_formatSize(file['size'])}  |  ${_formatDate(file['mtime'])}",
                  ),
            trailing: (!_isSelectionMode && file['is_dir'])
                ? const Icon(Icons.chevron_right)
                : null,
            onTap: () => _onItemTap(name, file['is_dir']),
            onLongPress: () => _onItemLongPress(name),
          );
        },
      ),
    );
  }

  // ✅ 补全的 _buildGridView
  Widget _buildGridView() {
    return RefreshIndicator(
      onRefresh: fetchFiles,
      child: GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
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
            onLongPress: () => _onItemLongPress(name),
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
                                      fit: BoxFit.cover,
                                      memCacheHeight: 200,
                                      placeholder: (c, u) =>
                                          Container(color: Colors.grey[200]),
                                      errorWidget: (c, u, e) => const Icon(
                                        Icons.broken_image,
                                        color: Colors.grey,
                                      ),
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
                      size: 24,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDate(dynamic t) {
    if (t == null) return "";
    var d = DateTime.fromMillisecondsSinceEpoch((t * 1000).toInt());
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
  }
}

class ImagePage extends StatelessWidget {
  final String url;
  const ImagePage({super.key, required this.url});
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
          placeholder: (c, u) => const CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class VideoPage extends StatefulWidget {
  final String url;
  const VideoPage({super.key, required this.url});
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
