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

  const IjkPlayerWidget({
    Key? key,
    required this.url,
    this.decoderIndex = 0,
    this.onError,
    this.onSpeedUpdate,
    this.headers,
  }) : super(key: key);

  @override
  State<IjkPlayerWidget> createState() => _IjkPlayerWidgetState();
}

class _IjkPlayerWidgetState extends State<IjkPlayerWidget> {
  MethodChannel? _channel;
  Timer? _speedTimer;
  bool _isLoading = true;
  late JavascriptRuntime _jsRuntime;
  String? _cryptoScript; // 缓存脚本内容

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
    _loadCryptoScript();
    _startSpeedTimer();
  }

  /// 加载 crypto.js 到内存
  Future<void> _loadCryptoScript() async {
    try {
      _cryptoScript = await rootBundle.loadString('assets/js/crypto.js');
    } catch (e) {
      // 如果没有 crypto.js，不影响解析
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

  /// 核心解析：完全模仿酷9的“先请求 → 判断 → 解密 → 提取”
  Future<String> _resolveUrl(String url) async {
    // 如果已是标准流地址，直接返回
    if (url.startsWith('http') && 
        (url.endsWith('.m3u8') || url.endsWith('.mp4') || url.endsWith('.ts') || url.endsWith('.flv'))) {
      return url;
    }

    try {
      // 1. 发起HTTP请求（酷9也是这么做的）
      final response = await http.get(
        Uri.parse(url),
        headers: _mergedHeaders,
      );
      if (response.statusCode != 200) return url;
      final body = response.body.trim();

      // 2. 如果 body 以 "#EXTM3U" 开头，说明本身就是m3u8
      if (body.startsWith('#EXTM3U')) return url;

      // 3. 如果 body 是 JSON，尝试提取 url 字段
      if (body.startsWith('{') || body.startsWith('[')) {
        try {
          final json = jsonDecode(body);
          if (json is Map) {
            // 检查是否有 "url"、"data.url"、"stream_url" 等
            for (var key in ['url', 'stream_url', 'play_url', 'video_url']) {
              if (json.containsKey(key) && json[key] is String && json[key].isNotEmpty) {
                return json[key];
              }
            }
            // 如果嵌套在 data 中
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

      // 4. 判断 body 是否加密（酷9常见：以 "U2FsdGVkX1" 开头）
      if (body.startsWith('U2FsdGVkX1') && _cryptoScript != null) {
        // 调用 crypto.js 进行 AES 解密
        final decrypted = await _decryptWithCryptoJS(body);
        if (decrypted != null && decrypted.isNotEmpty) {
          // 解密后可能是 JSON 或直接地址，再次提取
          if (decrypted.startsWith('http')) return decrypted;
          // 尝试从解密后的 JSON 中提取
          try {
            final json = jsonDecode(decrypted);
            if (json is Map && json.containsKey('url')) return json['url'].toString();
          } catch (_) {}
        }
      }

      // 5. 正则提取 http 链接（酷9也有类似 fallback）
      final regex = RegExp(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4|ts|flv)');
      final match = regex.firstMatch(body);
      if (match != null) return match.group(0)!;

      // 6. 如果什么都没提取到，返回原 URL
      return url;
    } catch (e) {
      return url;
    }
  }

  /// 使用 CryptoJS 解密字符串（酷9就是用这个库）
  Future<String?> _decryptWithCryptoJS(String encrypted) async {
    try {
      // 构造 JS 代码，执行解密
      final script = '''
        (function() {
          ${_cryptoScript!}
          // 假设加密内容是 AES 加密，用 CryptoJS.AES.decrypt
          // 需要知道密钥和模式，酷9可能从配置中获取，这里我们模拟
          // 实际你可能需要从 URL 或其他地方提取密钥
          var decrypted = CryptoJS.AES.decrypt('$encrypted', 'your_secret_key');
          return decrypted.toString(CryptoJS.enc.Utf8);
        })()
      ''';
      final result = _jsRuntime.evaluate(script);
      return result.stringResult;
    } catch (e) {
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
