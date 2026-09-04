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
  final String? secretKey; // 解密密钥，酷9可能从配置或URL获取

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

  Map<String, String> get _defaultHeaders => {
    'User-Agent': 'OKhttp/1.31',
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Accept-Encoding': 'identity',
    'Connection': 'keep-alive',
  };

  Map<String, String> get _mergedHeaders {
    final base = Map<String, String>.from(_defaultHeaders);
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
  }

  /// 加载 crypto.js 并初始化 CryptoJS
  Future<void> _initCrypto() async {
    try {
      final cryptoJsContent = await rootBundle.loadString('assets/js/crypto.js');
      // 将 crypto.js 包裹在 IIFE 中，并将 bt 挂载到全局
      final wrappedScript = '''
        (function() {
          ${cryptoJsContent}
          // 原文件末尾返回 bt，这里将其暴露到全局
          if (typeof global !== 'undefined') {
            global.CryptoJS = bt;
          } else if (typeof window !== 'undefined') {
            window.CryptoJS = bt;
          }
        })();
      ''';
      _jsRuntime.evaluate(wrappedScript);
      _cryptoReady = true;
    } catch (e) {
      print('加载 CryptoJS 失败: $e');
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
          if (mounted) setState(() => _isLoading = false);
          widget.onError?.call();
          break;
        case 'onInfo':
          final what = call.arguments['what'] as int?;
          if (what == 3 && mounted) {
            setState(() => _isLoading = false);
          }
          break;
      }
    });
    _play(widget.url, widget.decoderIndex);
  }

  /// 核心解析：模仿酷9的流程
  Future<String> _resolveUrl(String url) async {
    // 如果已是标准流地址，直接返回
    if (url.startsWith('http') && 
        (url.endsWith('.m3u8') || url.endsWith('.mp4') || url.endsWith('.ts') || url.endsWith('.flv'))) {
      return url;
    }

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _mergedHeaders,
      );
      if (response.statusCode != 200) return url;
      final body = response.body.trim();

      // 如果是 M3U8
      if (body.startsWith('#EXTM3U')) return url;

      // 如果是 JSON
      if (body.startsWith('{') || body.startsWith('[')) {
        try {
          final json = jsonDecode(body);
          if (json is Map) {
            for (var key in ['url', 'stream_url', 'play_url', 'video_url']) {
              if (json.containsKey(key) && json[key] is String && json[key].isNotEmpty) {
                return json[key];
              }
            }
            if (json.containsKey('data') && json['data'] is Map) {
              final data = json['data'] as Map;
              for (var key in ['url', 'stream_url', 'play_url']) {
                if (data.containsKey(key) && data[key] is String && data[key].isNotEmpty) {
                  return data[key];
                }
              }
            }
          }
        } catch (_) {}
      }

      // 检查是否 AES 加密（酷9常见）
      if (body.startsWith('U2FsdGVkX1') && _cryptoReady) {
        // 需要密钥：从 widget.secretKey 或从 URL 参数中提取
        final key = widget.secretKey ?? 'your_default_key';
        final decrypted = await _decryptAES(body, key);
        if (decrypted != null && decrypted.isNotEmpty) {
          // 解密后可能是 JSON，再提取
          if (decrypted.startsWith('http')) return decrypted;
          try {
            final json = jsonDecode(decrypted);
            if (json is Map && json.containsKey('url')) return json['url'].toString();
          } catch (_) {}
        }
      }

      // 正则提取
      final regex = RegExp(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4|ts|flv)');
      final match = regex.firstMatch(body);
      if (match != null) return match.group(0)!;

      return url;
    } catch (e) {
      return url;
    }
  }

  /// 使用 CryptoJS 解密 AES
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
      print('解密失败: $e');
      return null;
    }
  }

  Future<void> _play(String url, int decoderIndex) async {
    if (mounted) setState(() => _isLoading = true);
    final realUrl = await _resolveUrl(url);
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
            child: const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
      ],
    );
  }
}
