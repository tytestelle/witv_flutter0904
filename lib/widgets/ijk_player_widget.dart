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
    _startSpeedTimer();
    _jsRuntime = getJavascriptRuntime(); // 初始化 JS 引擎
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

  /// 核心解析方法：先尝试 JS 脚本，再 fallback 到 HTTP 解析
  Future<String> _resolveUrl(String url) async {
    // 1. 如果是标准流地址，直接返回
    if (url.startsWith('http') && 
        (url.endsWith('.m3u8') || url.endsWith('.mp4') || url.endsWith('.ts') || url.endsWith('.flv'))) {
      return url;
    }

    // 2. 尝试加载对应域名的 JS 脚本（可配置映射）
    String? domain;
    try {
      final uri = Uri.parse(url);
      domain = uri.host;
    } catch (_) {}

    if (domain != null) {
      // 尝试加载 assets/js/${domain}.js
      final scriptContent = await _loadScriptForDomain(domain);
      if (scriptContent != null) {
        try {
          // 执行脚本，调用 parse(url)
          final result = _jsRuntime.evaluate('''
            (function() {
              $scriptContent
              if (typeof parse === 'function') {
                return parse('$url');
              }
              return null;
            })()
          ''');
          if (result.stringResult != null && result.stringResult!.isNotEmpty) {
            return result.stringResult!;
          }
        } catch (e) {
          // JS 执行出错，继续 fallback
        }
      }
    }

    // 3. Fallback：HTTP 请求 + 正则/JSON 提取
    return await _httpResolve(url);
  }

  /// 从 assets 加载对应域名的 JS 脚本
  Future<String?> _loadScriptForDomain(String domain) async {
    try {
      // 假设脚本存放在 assets/js/ 下，文件名为域名.js
      return await rootBundle.loadString('assets/js/$domain.js');
    } catch (_) {
      return null;
    }
  }

  /// HTTP 解析方式（和之前一样）
  Future<String> _httpResolve(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _mergedHeaders,
      );
      if (response.statusCode != 200) return url;
      final body = response.body.trim();

      if (body.startsWith('#EXTM3U')) return url;

      if (body.startsWith('{') || body.startsWith('[')) {
        try {
          final json = jsonDecode(body);
          if (json is Map) {
            if (json['url'] != null && json['url'].toString().isNotEmpty) return json['url'].toString();
            if (json['data'] != null && json['data']['url'] != null) return json['data']['url'].toString();
            if (json['stream_url'] != null) return json['stream_url'].toString();
            if (json['play_url'] != null) return json['play_url'].toString();
          }
        } catch (_) {}
      }

      final regex = RegExp(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4|ts|flv)');
      final match = regex.firstMatch(body);
      if (match != null) return match.group(0)!;

      return url;
    } catch (_) {
      return url;
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
