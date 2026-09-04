import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// 解析 URL，提取真实视频地址
  Future<String> _resolveUrl(String url) async {
    // 如果已经是标准流地址，直接返回
    if (url.startsWith('http') && 
        (url.endsWith('.m3u8') || url.endsWith('.mp4') || url.endsWith('.ts') || url.endsWith('.flv'))) {
      return url;
    }

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _mergedHeaders, // 使用和播放器相同的 headers
      );

      if (response.statusCode != 200) {
        return url;
      }

      final body = response.body.trim();

      // 1. M3U8
      if (body.startsWith('#EXTM3U')) {
        return url;
      }

      // 2. JSON
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

      // 3. 正则提取
      final regex = RegExp(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4|ts|flv)');
      final match = regex.firstMatch(body);
      if (match != null) {
        return match.group(0)!;
      }

      return url;
    } catch (e) {
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
