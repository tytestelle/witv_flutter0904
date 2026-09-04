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
      print('IjkPlayer: CryptoJS 加载成功');
    } catch (e) {
      print('IjkPlayer: CryptoJS 加载失败: $e');
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
          print('IjkPlayer: 播放器错误回调');
          if (mounted) setState(() => _isLoading = false);
          widget.onError?.call();
          break;
        case 'onInfo':
          final what = call.arguments['what'] as int?;
          print('IjkPlayer: onInfo what=$what');
          if (what == 3 && mounted) {
            setState(() => _isLoading = false);
          }
          break;
      }
    });
    _play(widget.url, widget.decoderIndex);
  }

  Future<String> _resolveUrl(String url) async {
    print('IjkPlayer: 开始解析 URL: $url');
    if (url.startsWith('http') && 
        (url.endsWith('.m3u8') || url.endsWith('.mp4') || url.endsWith('.ts') || url.endsWith('.flv'))) {
      print('IjkPlayer: URL 已是标准流，直接返回');
      return url;
    }

    try {
      print('IjkPlayer: 发起 HTTP 请求...');
      final response = await http.get(
        Uri.parse(url),
        headers: _mergedHeaders,
      );
      print('IjkPlayer: HTTP 状态码: ${response.statusCode}');
      if (response.statusCode != 200) {
        print('IjkPlayer: HTTP 非200，返回原URL');
        return url;
      }
      final body = response.body.trim();
      print('IjkPlayer: 响应体前200字符: ${body.substring(0, body.length > 200 ? 200 : body.length)}');

      if (body.startsWith('#EXTM3U')) {
        print('IjkPlayer: 响应是 M3U8，返回原URL');
        return url;
      }

      if (body.startsWith('{') || body.startsWith('[')) {
        try {
          final json = jsonDecode(body);
          print('IjkPlayer: JSON 解析成功');
          if (json is Map) {
            for (var key in ['url', 'stream_url', 'play_url', 'video_url']) {
              if (json.containsKey(key) && json[key] is String && json[key].isNotEmpty) {
                print('IjkPlayer: 从 JSON 提取到地址: ${json[key]}');
                return json[key];
              }
            }
            if (json.containsKey('data') && json['data'] is Map) {
              final data = json['data'] as Map;
              for (var key in ['url', 'stream_url', 'play_url']) {
                if (data.containsKey(key) && data[key] is String && data[key].isNotEmpty) {
                  print('IjkPlayer: 从 JSON.data 提取到地址: ${data[key]}');
                  return data[key];
                }
              }
            }
          }
        } catch (e) {
          print('IjkPlayer: JSON 解析失败: $e');
        }
      }

      // AES 加密
      if (body.startsWith('U2FsdGVkX1') && _cryptoReady) {
        print('IjkPlayer: 检测到 AES 加密数据，尝试解密...');
        final key = widget.secretKey ?? 'default_key';
        final decrypted = await _decryptAES(body, key);
        if (decrypted != null && decrypted.isNotEmpty) {
          print('IjkPlayer: 解密结果: $decrypted');
          if (decrypted.startsWith('http')) return decrypted;
          try {
            final json = jsonDecode(decrypted);
            if (json is Map && json.containsKey('url')) {
              print('IjkPlayer: 从解密后的 JSON 提取到地址: ${json['url']}');
              return json['url'];
            }
          } catch (_) {}
        }
      }

      // 简单提取 http://
      final start = body.indexOf('http://');
      if (start != -1) {
        final end = body.indexOf(' ', start);
        final candidate = end == -1 ? body.substring(start) : body.substring(start, end);
        if (candidate.endsWith('.m3u8') || 
            candidate.endsWith('.mp4') || 
            candidate.endsWith('.ts') || 
            candidate.endsWith('.flv')) {
          print('IjkPlayer: 从响应中提取到候选地址: $candidate');
          return candidate;
        }
      }

      print('IjkPlayer: 未找到有效地址，返回原URL');
      return url;
    } catch (e) {
      print('IjkPlayer: 解析异常: $e');
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
      print('IjkPlayer: AES 解密失败: $e');
      return null;
    }
  }

  Future<void> _play(String url, int decoderIndex) async {
    if (mounted) setState(() => _isLoading = true);
    final realUrl = await _resolveUrl(url);
    print('IjkPlayer: 最终播放地址: $realUrl');
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
