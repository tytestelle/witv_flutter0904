import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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
  String _debugInfo = '准备...';

  // 酷9的请求头（完整复制）
  Map<String, String> get _cool9Headers => {
    'User-Agent': 'OKhttp/1.31',
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Accept-Encoding': 'gzip, deflate',
    'Connection': 'keep-alive',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };

  Map<String, String> get _mergedHeaders {
    final base = Map<String, String>.from(_cool9Headers);
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
    // 延迟一帧确保 channel 已准备好
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _play(widget.url, widget.decoderIndex);
    });
  }

  Future<void> _initCrypto() async {
    try {
      final cryptoJsContent = await rootBundle.loadString('assets/js/crypto.js');
      // 注意：crypto.js 是模块，我们直接注入并暴露 CryptoJS
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
      _updateDebug('CryptoJS 就绪');
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

  /// 核心解析器，尝试所有酷9可能的方式
  Future<String> _resolveUrl(String url) async {
    _updateDebug('开始解析: $url');
    if (url.startsWith('http') && 
        (url.endsWith('.m3u8') || url.endsWith('.mp4') || url.endsWith('.ts') || url.endsWith('.flv'))) {
      _updateDebug('标准流，直接播放');
      return url;
    }

    try {
      _updateDebug('发送HTTP请求...');
      final response = await http.get(
        Uri.parse(url),
        headers: _mergedHeaders,
      );
      _updateDebug('HTTP状态: ${response.statusCode}');
      if (response.statusCode != 200) {
        _updateDebug('HTTP错误，返回原URL');
        return url;
      }
      final body = response.body.trim();
      _updateDebug('响应预览: ${body.substring(0, body.length > 100 ? 100 : body.length)}');

      // 1. M3U8
      if (body.startsWith('#EXTM3U')) {
        _updateDebug('M3U8内容，直接播放');
        return url;
      }

      // 2. JSON 提取
      if (body.startsWith('{') || body.startsWith('[')) {
        try {
          final json = jsonDecode(body);
          _updateDebug('JSON解析成功');
          if (json is Map) {
            // 常见字段
            for (var key in ['url', 'stream_url', 'play_url', 'video_url', 'data.url']) {
              final parts = key.split('.');
              var current = json;
              var found = true;
              for (var part in parts) {
                if (current is Map && current.containsKey(part)) {
                  current = current[part];
                } else {
                  found = false;
                  break;
                }
              }
              if (found && current is String && current.isNotEmpty) {
                _updateDebug('从JSON提取: $current');
                return current;
              }
            }
            // 如果顶层就包含 url
            if (json.containsKey('url') && json['url'] is String && json['url'].isNotEmpty) {
              _updateDebug('从JSON.url提取: ${json['url']}');
              return json['url'];
            }
          }
        } catch (e) {
          _updateDebug('JSON解析失败: $e');
        }
      }

      // 3. AES 加密
      if (body.startsWith('U2FsdGVkX1') && _cryptoReady) {
        _updateDebug('检测到AES加密，尝试解密...');
        final key = widget.secretKey ?? 'default_key';
        final decrypted = await _decryptAES(body, key);
        if (decrypted != null && decrypted.isNotEmpty) {
          _updateDebug('解密结果: $decrypted');
          if (decrypted.startsWith('http')) return decrypted;
          try {
            final json = jsonDecode(decrypted);
            if (json is Map && json.containsKey('url')) {
              _updateDebug('从解密JSON提取: ${json['url']}');
              return json['url'];
            }
          } catch (_) {}
        }
      }

      // 4. 简单提取 http://... 链接
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
      _updateDebug('AES解密失败: $e');
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      _debugInfo,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
