import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 用于剪贴板功能
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:camera/camera.dart'; // 引入 camera 包以控制 Zoom/Torch
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:zstandard/zstandard.dart'; // 用于 ZSTD 解压缩

class MobileQRScannerScreen extends StatefulWidget {
  const MobileQRScannerScreen({super.key});

  @override
  State<MobileQRScannerScreen> createState() => _MobileQRScannerScreenState();
}

class _MobileQRScannerScreenState extends State<MobileQRScannerScreen> {
  bool _hasPermission = false;
  String? errorMessage;
  String _progressText = 'Ready to scan';
  double _progressValue = 0.0;
  bool _isWakeLockEnabled = false;

  // TXQR decoder variables
  final Map<String, dynamic> _txqrCache = {};
  List<Uint8List> _receivedChunks = [];
  bool _isComplete = false;
  int _totalSize = 0;
  Uint8List _decodedData = Uint8List(0);
  int _chunksReceived = 0;
  int _totalChunks = 0;
  Set<int> _missingChunks = {};

  CameraController? _cameraController;
  bool _isTorchOn = false;
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;

  double _zoomFactor = 0.0;
  final double _minZoom = 0.0;
  final double _maxZoom = 1.0;

  bool _isJsonDialogShowing = false; // 防止重复弹出 JSON 对话框
  
  bool _isCompressed = false;// 添加压缩相关变量
  int _compressionLevel = -1;
  int _version = 1;
  int _chunkSize = 0;
  String _hash = '';

  bool _inited = false;
  String _filename = '';

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    setState(() {
      _hasPermission = status == PermissionStatus.granted;
    });
  }

  Future<void> _processTxqrData(Uint8List data) async {
    if (data.isEmpty || data.length < 4 || data[0]==0x7b) {
      return; // Invalid frame
    }

    int pipeIndex = data.indexOf(0x7c); // 0x7c is the ASCII value for '|'
    if (pipeIndex == -1) {
      return; // Invalid frame
    }

    String header = String.fromCharCodes(data.sublist(0, pipeIndex));
    Uint8List payload = data.sublist(pipeIndex + 1);

    // Parse header: blockCode/chunkSize/totalSize
    List<String> headerParts = header.split('/');

    int blockCode = -1;
    if(_version==1){
      if (headerParts.length < 3 || headerParts.length > 4) {
        _showSnackBar("Invalid header format. If it is version 2 or higher, please scan the metadata QR code first.", Colors.red);
        return; // Invalid header
      }
      blockCode = int.tryParse(headerParts[0]) ?? -1;
      int chunkSize = int.tryParse(headerParts[1]) ?? 0;
      int totalSize = int.tryParse(headerParts[2]) ?? 0;

      // Initialize if this is the first chunk
      if (!_inited) {
        _initDecoder(totalChunks: ((totalSize / chunkSize).ceil()), fileSize: totalSize,hash: '',version: 1);
        _inited = true;
      }
    } else if(_version==2){
      blockCode = int.tryParse(headerParts[0]) ?? -1;
      if(!_hash.startsWith(headerParts[1])){
        _showSnackBar("QR code hash mismatch", Colors.red);
        return; // Hash mismatch
      }
    }else{
      _showSnackBar("Unsupported version", Colors.red);
      return; // Unsupported version
    }
     

    if (blockCode < 0) {
      return; // Invalid block code
    }

    // Check if this chunk has already been processed
    if (_txqrCache.containsKey(header)) {
      return; // Skip duplicate
    }

    // Cache this header to prevent duplicates
    _txqrCache[header] = true;

    // Store the chunk
    if (blockCode < _receivedChunks.length) {
      if(_isCompressed)payload = await _decompressData(payload);
      _receivedChunks[blockCode] = payload;
      // Remove this chunk from missing chunks set
      _missingChunks.remove(blockCode);
      _chunksReceived++;

      // Update progress
      setState(() {
        _progressValue = _chunksReceived / _totalChunks;
        _progressText = 'Received $_chunksReceived of $_totalChunks chunks\n(Missing blocks: ${_getMissingChunksDisplay()})';
      });
    }

    // Check if we have received all chunks
    bool allReceived = true;
    for (Uint8List chunk in _receivedChunks) {
      if (chunk.isEmpty) {
        allReceived = false;
        break;
      }
    }

    if (allReceived) {
      // Reconstruct the full data
      final bBuilder = BytesBuilder();
      for (final chunk in _receivedChunks) {
        bBuilder.add(chunk);
      }
      Uint8List fullData = bBuilder.takeBytes();

      try {
        Uint8List decodedBytes = fullData;
        _decodedData = decodedBytes;
        _isComplete = true;

        // Update progress
        setState(() {
          _progressValue = 1.0;
          _progressText = 'File received!';
        });

        // Show success dialog and save file
        _showSaveFileDialog();
      } catch (e) {
        setState(() {
          _progressText = 'Error decoding data';
        });
      }
    }
  }

  void _showSaveFileDialog() {
    if(_filename.isEmpty){
      _filename = 'txqr_file_${DateTime.now().millisecondsSinceEpoch}.bin';
    }
    TextEditingController fileNameController = TextEditingController(text: _filename);

    List<Widget> contentWidgets = [
      const Text('Enter filename:'),
      TextField(
        controller: fileNameController,
        decoration: const InputDecoration(
          hintText: 'Filename',
          border: OutlineInputBorder(),
        ),
      ),
    ];

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Save File'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: contentWidgets,
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                // Reset decoder if user cancels
                _resetDecoder();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop(); // Close dialog
                await _saveFile(_decodedData, fileNameController.text);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

// 添加解压缩方法
Future<Uint8List> _decompressData(Uint8List compressedData) async {
  try {
    final zstandard = Zstandard();
    // 使用 zstandard 库进行解压缩
    Uint8List decompressedData = await zstandard.decompress(compressedData)??(Uint8List(0));

    return decompressedData;
  } catch (e) {
    _showSnackBar('Decompression failed: $e', Colors.red);
    rethrow;
  }
}

Future<void> _saveFile(Uint8List content, String fileName) async {
  try {
    Uint8List bytesToSave = content;

    if (Platform.isAndroid) {
      // --- 安卓专用逻辑：使用 MediaStore ---
      final mediaStore = MediaStore();

      // 1. 先写到临时文件
      final tempDir = await getTemporaryDirectory();
      // 建议给文件名加时间戳，避免 Android 14 上的重名所有权冲突
      String uniqueName = "${DateTime.now().millisecondsSinceEpoch}_$fileName";
      final tempFile = File('${tempDir.path}/$uniqueName');
      await tempFile.writeAsBytes(bytesToSave);

      // 2. 使用 MediaStore 保存到公共 Download/TXQR_Files 目录
      await mediaStore.saveFile(
        tempFilePath: tempFile.path,
        dirType: DirType.download,
        dirName: DirName.download,
        relativePath: "TXQR_Files",
      );

      // 3. 清理临时文件
      if (await tempFile.exists()) await tempFile.delete();

      _showSnackBar('文件已存入公共下载目录: Download/TXQR_Files/$uniqueName', Colors.green);

    } else {
      // --- 其他平台逻辑：iOS / Desktop ---
      Directory? targetDir = await getDownloadsDirectory();
      targetDir ??= await getApplicationDocumentsDirectory();

      Directory txqrDir = Directory('${targetDir.path}/TXQR_Files');
      if (!await txqrDir.exists()) {
        await txqrDir.create(recursive: true);
      }

      String filePath = '${txqrDir.path}/$fileName';
      File file = File(filePath);
      await file.writeAsBytes(bytesToSave);

      _showSnackBar('文件保存成功: $filePath', Colors.green);
    }

    _resetDecoder(); // 重置解码器

  } catch (e) {

    _showSnackBar('保存失败: $e', Colors.red);
  }
}

// 提取的辅助函数
  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }
  String _getMissingChunksDisplay() {
    if (_missingChunks.isEmpty) {
      return 'None';
    }
    
    // Sort the missing chunks for better readability
    List<int> sortedMissing = _missingChunks.toList()..sort();
    
    // If there are many missing chunks, show the count and the first few indices
    if (sortedMissing.length > 10) {
      List<int> firstFew = sortedMissing.take(5).toList();
      return '${firstFew.join(', ')}...';
    }
    
    // Otherwise, show the actual indices
    return sortedMissing.join(', ');
  }

  void _resetDecoder() {
    _txqrCache.clear();
    _receivedChunks.clear();
    _isComplete = false;
    _totalSize = 0;
    _decodedData = Uint8List(0);
    _chunksReceived = 0;
    _totalChunks = 0;
    _missingChunks.clear();
    _progressValue = 0.0;
    _progressText = 'Ready to scan';
    _isCompressed = false;
    _compressionLevel = -1;
    _inited = false;

    // Update UI to reflect reset
    if (mounted) {
      setState(() {});
    }
  }

  /// 检查字符串是否为有效的JSON格式
  Map<String, dynamic>? _isJsonString(String str) {
    if (str.startsWith('{')) {
      try {
        final parsed = json.decode(str);
        // 确保解析后的对象是Map类型（简单键值对）
        if (parsed is Map<String, dynamic>) {
          return parsed;
        }
      } catch (e) {
        // 如果解析失败，则不是有效JSON
        return null;
      }
    }
    return null;
  }

  /// 显示JSON数据的对话框
  void _showJsonDialog(Map<String, dynamic> jsonData) {
    // 检查是否包含元数据字段
    bool isMetadata = jsonData.containsKey('filename') &&
                      jsonData.containsKey('compression') &&
                      jsonData.containsKey('hash') &&
                      jsonData.containsKey('chunk_size') &&
                      jsonData.containsKey('total_chunks') &&
                      jsonData.containsKey('file_size');
    
    if (isMetadata) {
      // 如果是元数据，显示确认对话框
      _showMetadataConfirmationDialog(jsonData);
    }
  }

  /// 显示元数据确认对话框
  void _showMetadataConfirmationDialog(Map<String, dynamic> jsonData) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('File Metadata Detected'),
          content: SizedBox(
            width: double.maxFinite, // 允许对话框宽度扩展
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: jsonData.length,
              itemBuilder: (context, index) {
                final key = jsonData.keys.elementAt(index);
                final value = jsonData[key].toString();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 键部分 - 长按复制键
                      GestureDetector(
                        onLongPress: () {
                          Clipboard.setData(ClipboardData(text: key));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Key copied to clipboard')),
                          );
                        },
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            '$key:',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      // 值部分 - 长按复制值
                      GestureDetector(
                        onLongPress: () {
                          Clipboard.setData(ClipboardData(text: value));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Value copied to clipboard')),
                          );
                        },
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            value,
                            softWrap: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // 取消
                _isJsonDialogShowing = false;
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                // 确认并更新文件信息
                Navigator.of(context).pop(); // 关闭对话框
                _updateFileInfoFromMetadata(jsonData);
                _isJsonDialogShowing = false;
              },
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    ).then((_) {
      _isJsonDialogShowing = false;
    });
  }

  /// 从元数据更新文件信息
  void _updateFileInfoFromMetadata(Map<String, dynamic> metadata) {
    // 更新内部变量
    String filename = metadata['filename']?.toString() ?? 'unknown_file.bin';
    
    // 解析新的压缩字段格式：如果是 "ZSTD-{level}" 格式，则提取压缩级别；否则为 "None"
    String compressionInfo = metadata['compression']?.toString() ?? 'None';
    bool compression = compressionInfo != 'None';
    int compressionLevel = -1;
    
    if (compression && compressionInfo.startsWith('ZSTD-')) {
      try {
        compressionLevel = int.parse(compressionInfo.substring(5)); // 移除 "ZSTD-" 前缀
      } catch (e) {
        compressionLevel = -1; // 解析失败时设为 -1
      }
    }
    
    String hash = metadata['hash']?.toString() ?? '';
    int chunkSize = metadata['chunk_size'] ?? 2100;
    int totalChunks = metadata['total_chunks'] ?? 0;
    int fileSize = metadata['file_size'] ?? 0;
    int version = metadata['version'] ?? 1;
    _initDecoder(totalChunks: totalChunks, fileSize: fileSize, filename: filename,
                compression: compression, compressionLevel: compressionLevel,version: version,
                hash: hash,chunkSize: chunkSize);

    _showSnackBar('File info updated from metadata: $filename', Colors.green);
  }

  void _initDecoder({required int totalChunks, required int fileSize, String filename="",
                     bool compression=false, int compressionLevel=-1,int version=1,
                     required String hash,int chunkSize=0}) {
    _resetDecoder();

    // 更新UI状态
    setState(() {
      _isCompressed = compression;
      _compressionLevel = compressionLevel;
      _totalSize = fileSize;
      _totalChunks = totalChunks;
      _receivedChunks = List.filled(_totalChunks, Uint8List(0), growable: true);
      // Initialize missing chunks set with all expected chunk indices
      _missingChunks = Set<int>.from(List.generate(_totalChunks, (index) => index));
      _progressText = 'Metadata loaded. Ready to receive $totalChunks data chunks for file: $filename';
      _progressValue = 0.0;
      _filename = filename;
      _inited = true;
      _version = version;
      _hash = hash;
      _chunkSize = chunkSize;
    });
  }

  Future<void> _toggleWakeLock() async {
    if (_isWakeLockEnabled) {
      await WakelockPlus.disable();
      setState(() {
        _isWakeLockEnabled = false;
      });
    } else {
      await WakelockPlus.enable();
      setState(() {
        _isWakeLockEnabled = true;
      });
    }
  }

  Future<void> _exportPartialData() async {
    // 如果检测到压缩，禁用部分导出功能并显示提示
    /*if (_isCompressed) {
      _showSnackBar('Partial export disabled for compressed files', Colors.orange);
      return;
    }*/

    if (_totalSize <= 0 || _receivedChunks.isEmpty) {
      _showSnackBar('No data received yet', Colors.orange);
      return;
    }

    // Calculate expected chunk size
    int expectedChunkSize = 0;
    if(_chunkSize>0){
      expectedChunkSize = _chunkSize;
    }else{
      expectedChunkSize = _receivedChunks.map((chunk) => chunk.length).fold(0, (prev, len) => max(prev, len));
    }

    // Create a complete data buffer filled with zeros
    Uint8List completeData = Uint8List(_totalSize);

    // Fill in the received chunks at their correct positions
    for (int i = 0; i < _receivedChunks.length; i++) {
      Uint8List chunk = _receivedChunks[i];
      if (chunk.isNotEmpty) {
        int startPos = i * expectedChunkSize;
        int endPos = startPos + chunk.length;

        // Ensure we don't exceed the total size
        if (startPos < _totalSize) {
          if (endPos > _totalSize) {
            endPos = _totalSize;
          }

          // Copy the chunk to the correct position in the complete data
          completeData.setRange(startPos, endPos, chunk);
        }
      }
    }

    // Save the partially reconstructed data
    String fileName = '${DateTime.now().millisecondsSinceEpoch}_partial_$_filename';
    await _saveFile(completeData, fileName);
  }

  // Helper method to set camera zoom using the 0.0-1.0 slider value
  Future<void> _setCameraZoom(double value) async {
    if (_cameraController == null) return;
    try {
      // Map 0-1 to minZoom-maxZoom
      final double realZoom = _minZoomLevel + (value * (_maxZoomLevel - _minZoomLevel));
      await _cameraController!.setZoomLevel(realZoom);
    } catch (e) {
      debugPrint("Error setting zoom: $e");
    }
  }

  // Helper method to toggle torch
  Future<void> _toggleCameraTorch() async {
    if (_cameraController == null) return;
    try {
      final bool newStatus = !_isTorchOn;
      await _cameraController!.setFlashMode(newStatus ? FlashMode.torch : FlashMode.off);
      setState(() {
        _isTorchOn = newStatus;
      });
    } catch (e) {
      debugPrint("Error toggling torch: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TXQR Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: _hasPermission
                ? ReaderWidget(
                    cropPercent: 0, // 设置为 0 表示不裁剪，识别全屏区域
                    showScannerOverlay: false, // 隐藏中间的扫描框 UI
                    onScan: (result) {
                      if (_isJsonDialogShowing) return;
                      if (!result.isValid) return;
                      
                      final Uint8List? rawValue = result.rawBytes;
                      
                      // 首先检查是否为JSON数据
                      if (rawValue != null && _inited == false) {
                        try {
                          String dataStr = utf8.decode(rawValue).trim();
                          Map<String, dynamic>? jsonData = _isJsonString(dataStr);
                          if (jsonData != null) {
                            _isJsonDialogShowing = true;
                            _showJsonDialog(jsonData);
                            return; 
                          }
                        } catch(e) {
                          // Ignore encoding errors for non-text data
                        }
                      }
                      
                      // 然后尝试处理TXQR协议数据
                      if (rawValue != null) {
                        // Process the scanned data using TXQR protocol
                        _processTxqrData(rawValue);
                      }
                    },
                    // 获取 CameraController 以控制 Zoom 和 Flash
                    onControllerCreated: (CameraController? controller,Exception? e) async {
                      if (e != null) {
                        debugPrint("Error creating camera controller: $e");
                        return;
                      }
                       _cameraController = controller;
                       if (_cameraController != null) {
                         try {
                           _minZoomLevel = await _cameraController!.getMinZoomLevel();
                           _maxZoomLevel = await _cameraController!.getMaxZoomLevel();
                         } catch (e) {
                           debugPrint("Error getting zoom levels: $e");
                         }
                       }
                       //return true;
                    },
                    scanDelay: const Duration(milliseconds: 100), // 防止扫描过快
                    resolution: ResolutionPreset.high,
                  )
                : Container(
                    alignment: Alignment.center,
                    child: const Text('Waiting for camera permission...'),
                  ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(6.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Zoom slider
                  Slider(
                    value: _zoomFactor,
                    min: _minZoom,
                    max: _maxZoom,
                    onChanged: (value) {
                      setState(() {
                        _zoomFactor = value;
                      });
                      _setCameraZoom(value);
                    },
                    label: 'Zoom: ${(_zoomFactor * 100).round()}%',
                  ),
                  // Progress indicator with reset button
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              _progressText,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: const TextStyle(fontSize: 14),
                            ),
                            LinearProgressIndicator(value: _progressValue),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: _resetDecoder,
                        tooltip: 'Reset Scanner',
                      ),
                    ],
                  ),

                  if (errorMessage != null)
                    Text(
                      'Error: $errorMessage',
                      style: const TextStyle(color: Colors.red),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: Icon(_isWakeLockEnabled ? Icons.bedtime_off : Icons.bedtime),
                        onPressed: _toggleWakeLock,
                        tooltip: _isWakeLockEnabled ? 'Disable Keep Awake' : 'Keep Awake',
                      ),
                      IconButton(
                        icon: const Icon(Icons.save),
                        onPressed: _exportPartialData,
                        tooltip: 'Export Partial Data',
                      ),
                      IconButton(
                        icon: Icon(_isTorchOn ? Icons.flashlight_off : Icons.flashlight_on),
                        onPressed: () async {
                            await _toggleCameraTorch();
                        },
                        tooltip: 'Toggle Flashlight',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}