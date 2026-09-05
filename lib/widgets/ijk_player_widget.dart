import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

class IjkPlayerWidget extends StatefulWidget {
  final String url;
  final int decoderIndex;
  final VoidCallback? onError;
  final ValueChanged<double>? onSpeedUpdate;
  final Map<String, String>? headers;
  final String? secretKey;

  const IjkPlayerWidget({
    Key? key,
    required this.url,
    this.decoderIndex = 0,
    this.onError,
    this.onSpeedUpdate,
    this.headers,
    this.secretKey,
  }) : super(key: key);

  @override
  State<IjkPlayerWidget> createState() => _IjkPlayerWidgetState();
}

class _IjkPlayerWidgetState extends State<IjkPlayerWidget> {
  MethodChannel? _channel;
  Timer? _speedTimer;
  bool _isLoading = true;
  late JavascriptRuntime _jsRuntime;
  bool _cryptoReady = false;
  String _debugInfo = '初始化...';

  // TVBox 风格的请求头
  Map<String, String> get _tvBoxHeaders => {
    'User-Agent': 'OKhttp/1.31',
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Accept-Encoding': 'gzip, deflate',
    'Connection': 'keep-alive',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };

  Map<String, String> get _mergedHeaders {
    final base = Map<String, String>.from(_tvBoxHeaders);
    try {
      final uri = Uri.parse(widget.url);
      base['Referer'] = '${uri.scheme}://${uri.host}/';
      base['Origin'] = '${uri.scheme}://${uri.host}';
      base['Host'] = uri.host;
    } catch (_) {}
    if (widget.headers != null) {
      base.addAll(widget.headers!);
    }
    return base;
  }

  @override
  void initState() {
    super.initState();
    _jsRuntime = getJavascriptRuntime();
    _initCrypto();
    _startSpeedTimer();
    _play(widget.url, widget.decoderIndex);
  }

  Future<void> _initCrypto() async {
    try {
      final cryptoJsContent = await rootBundle.loadString('assets/js/crypto.js');
      final wrappedScript = '''
        (function() {
          ${cryptoJsContent}
          if (typeof global !== 'undefined') {
            global.CryptoJS = bt;
          } else if (typeof window !== 'undefined') {
            window.CryptoJS = bt;
          }
        })();
      ''';
      _jsRuntime.evaluate(wrappedScript);
      _cryptoReady = true;
      _updateDebug('CryptoJS 加载成功');
    } catch (e) {
      _updateDebug('CryptoJS 加载失败: $e');
    }
  }

  void _updateDebug(String msg) {
    print('IjkPlayer: $msg');
    if (mounted) {
      setState(() {
        _debugInfo = msg;
      });
    }
  }

  @override
  void didUpdateWidget(covariant IjkPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url ||
        widget.decoderIndex != oldWidget.decoderIndex ||
        widget.headers != oldWidget.headers) {
      _play(widget.url, widget.decoderIndex);
    }
  }

  void _startSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.onSpeedUpdate?.call(0.0);
    });
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('ijkplayer_view_$id');
    _channel?.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onError':
          _updateDebug('播放器错误');
          if (mounted) setState(() => _isLoading = false);
          widget.onError?.call();
          break;
        case 'onInfo':
          final what = call.arguments['what'] as int?;
          _updateDebug('onInfo: $what');
          if (what == 3 && mounted) {
            setState(() => _isLoading = false);
          }
          break;
      }
    });
  }

  /// TVBox 风格解析器：先请求 → 判读响应类型 → 提取地址
  Future<String> _resolveUrl(String url) async {
    _updateDebug('开始解析: $url');

    // 如果已经是标准流地址，直接返回
    if (url.startsWith('http') &&
        (url.endsWith('.m3u8') || url.endsWith('.mp4') ||
         url.endsWith('.ts') || url.endsWith('.flv'))) {
      _updateDebug('标准流，直接播放');
      return url;
    }

    try {
      _updateDebug('发起HTTP请求 (超时15秒)...');
      final response = await http
          .get(
            Uri.parse(url),
            headers: _mergedHeaders,
          )
          .timeout(const Duration(seconds: 15), onTimeout: () {
            throw Exception('请求超时');
          });

      _updateDebug('HTTP状态: ${response.statusCode}');
      if (response.statusCode != 200) {
        _updateDebug('HTTP非200，返回原URL');
        return url;
      }

      final body = response.body.trim();
      _updateDebug('响应长度: ${body.length} 字符');
      final preview = body.length > 200 ? body.substring(0, 200) : body;
      _updateDebug('响应预览: $preview');

      // ============================================================
      // 以下逻辑完全参考 TVBox 的 LivePlayActivity 解析流程
      // ============================================================

      // 1. 如果是 M3U8 内容，直接播放
      if (body.startsWith('#EXTM3U')) {
        _updateDebug('检测到 M3U8 内容');
        return url;
      }

      // 2. 尝试 JSON 解析（TVBox 最常见的直播源格式）
      if (body.startsWith('{') || body.startsWith('[')) {
        try {
          final json = jsonDecode(body);
          _updateDebug('JSON 解析成功');

          // TVBox 常见的 JSON 字段：url, stream_url, play_url, video_url, data.url
          if (json is Map) {
            // 检查顶层字段
            for (var key in ['url', 'stream_url', 'play_url', 'video_url']) {
              final value = json[key];
              if (value is String && value.isNotEmpty && value.startsWith('http')) {
                _updateDebug('从 JSON 提取: $value');
                return value;
              }
            }
            // 检查 data 嵌套
            if (json.containsKey('data') && json['data'] is Map) {
              final data = json['data'] as Map;
              for (var key in ['url', 'stream_url', 'play_url']) {
                final value = data[key];
                if (value is String && value.isNotEmpty && value.startsWith('http')) {
                  _updateDebug('从 JSON.data 提取: $value');
                  return value;
                }
              }
            }
            // TVBox 有时直接把地址放在第一个字符串值里
            for (var value in json.values) {
              if (value is String && value.startsWith('http') &&
                  (value.endsWith('.m3u8') || value.endsWith('.mp4') ||
                   value.endsWith('.ts') || value.endsWith('.flv'))) {
                _updateDebug('从 JSON 值提取: $value');
                return value;
              }
            }
          }
        } catch (e) {
          _updateDebug('JSON 解析失败: $e');
        }
      }

      // 3. AES 加密（TVBox 常见：U2FsdGVkX1... 开头的 AES 密文）
      if (body.startsWith('U2FsdGVkX1') && _cryptoReady) {
        _updateDebug('检测到 AES 加密，尝试解密...');
        final key = widget.secretKey ?? 'default_key';
        final decrypted = await _decryptAES(body, key);
        if (decrypted != null && decrypted.isNotEmpty) {
          _updateDebug('解密结果: $decrypted');
          if (decrypted.startsWith('http')) return decrypted;
          try {
            final json = jsonDecode(decrypted);
            if (json is Map && json.containsKey('url')) {
              final value = json['url'];
              if (value is String && value.isNotEmpty) {
                _updateDebug('从解密 JSON 提取: $value');
                return value;
              }
            }
          } catch (_) {}
        }
      }

      // 4. Base64 编码（TVBox 也常见）
      try {
        final decoded = base64Decode(body);
        final decodedStr = utf8.decode(decoded);
        if (decodedStr.startsWith('http')) {
          _updateDebug('Base64 解码得到地址: $decodedStr');
          return decodedStr;
        }
        // 解码后可能是 JSON
        if (decodedStr.startsWith('{') || decodedStr.startsWith('[')) {
          final json = jsonDecode(decodedStr);
          if (json is Map) {
            for (var key in ['url', 'stream_url', 'play_url']) {
              final value = json[key];
              if (value is String && value.isNotEmpty && value.startsWith('http')) {
                _updateDebug('从 Base64 解码的 JSON 提取: $value');
                return value;
              }
            }
          }
        }
      } catch (_) {}

      // 5. 正则提取（TVBox fallback）
      final regex = RegExp(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4|ts|flv)');
      final match = regex.firstMatch(body);
      if (match != null) {
        _updateDebug('正则提取: ${match.group(0)}');
        return match.group(0)!;
      }

      // 6. 简单提取 http:// 开头的链接
      final start = body.indexOf('http://');
      if (start != -1) {
        final end = body.indexOf(' ', start);
        final candidate = end == -1 ? body.substring(start) : body.substring(start, end);
        if (candidate.endsWith('.m3u8') || candidate.endsWith('.mp4') ||
            candidate.endsWith('.ts') || candidate.endsWith('.flv')) {
          _updateDebug('简单提取: $candidate');
          return candidate;
        }
      }

      _updateDebug('未找到有效地址，返回原URL');
      return url;
    } catch (e) {
      _updateDebug('解析异常: $e');
      return url;
    }
  }

  Future<String?> _decryptAES(String encrypted, String key) async {
    try {
      final script = '''
        (function() {
          var decrypted = global.CryptoJS.AES.decrypt('$encrypted', '$key');
          return decrypted.toString(global.CryptoJS.enc.Utf8);
        })()
      ''';
      final result = _jsRuntime.evaluate(script);
      return result.stringResult;
    } catch (e) {
      _updateDebug('AES 解密失败: $e');
      return null;
    }
  }

  Future<void> _play(String url, int decoderIndex) async {
    if (mounted) setState(() => _isLoading = true);
    final realUrl = await _resolveUrl(url);
    _updateDebug('最终播放地址: $realUrl');
    _channel?.invokeMethod('setUrl', {
      'url': realUrl,
      'decoderIndex': decoderIndex,
      'headers': _mergedHeaders,
    });
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _channel?.invokeMethod('release');
    _jsRuntime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AndroidView(
          viewType: 'ijkplayer_view',
          creationParams: {
            'url': widget.url,
            'decoderIndex': widget.decoderIndex,
          },
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
        if (_isLoading)
          Container(
            color: Colors.black,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _debugInfo,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
