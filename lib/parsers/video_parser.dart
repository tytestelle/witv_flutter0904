import 'package:http/http.dart' as http;

/// 视频源解析器：输入原始URL，返回可播放的视频地址（如m3u8/mp4）
typedef VideoParser = Future<String> Function(String url);

/// 默认解析器：尝试直接请求，提取视频地址
class DefaultVideoParser {
  static Future<String> parse(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'OKhttp/1.31',
          'Accept': '*/*',
        },
      );
      if (response.statusCode != 200) {
        throw Exception('请求失败，状态码: ${response.statusCode}');
      }
      final body = response.body.trim();
      
      // 如果返回的是M3U8内容（以#EXTM3U开头），直接使用原URL（因为可能是重定向后的地址）
      if (body.startsWith('#EXTM3U')) {
        return url; // 实际上此时原URL就是m3u8地址
      }
      
      // 如果返回的是JSON，尝试解析
      if (body.startsWith('{')) {
        // 假设JSON中有url字段
        final json = Map<String, dynamic>.from(await Future.value(null)); // 这里简化，实际用dart:convert
        // 使用dart:convert
        final decoded = Uri.parse('').queryParameters; // 占位
        // 实际需要 import 'dart:convert';
        // 我们稍后实现
      }
      
      // 否则尝试正则提取视频地址（可能包含http链接）
      final regex = RegExp(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4|ts|flv)');
      final match = regex.firstMatch(body);
      if (match != null) {
        return match.group(0)!;
      }
      
      // 如果什么都没有，就返回原URL（死马当活马医）
      return url;
    } catch (e) {
      throw Exception('解析失败: $e');
    }
  }
}
