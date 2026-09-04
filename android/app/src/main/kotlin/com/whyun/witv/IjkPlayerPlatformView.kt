package com.whyun.witv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.AudioManager
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer

class IjkPlayerPlatformView(
    context: Context,
    private val viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val container = FrameLayout(context)
    private val textureView = TextureView(context)
    private val snapView = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_XY
        visibility = View.GONE
    }

    private var mediaPlayer: IjkMediaPlayer? = null
    private var methodChannel: MethodChannel? = null
    private var currentSurface: Surface? = null
    private var isSurfaceAvailable = false

    // 当前解码模式：0-硬解（默认），1-软解
    private var currentDecoderMode = 0

    init {
        IjkMediaPlayer.loadLibrariesOnce(null)

        // ========== 注册自定义协议（如需支持加密链接，请在此处添加） ==========
        // 如果你有自己的加密协议（如 crypto://），需要在此调用 native 方法注册
        // 例如：registerCustomProtocol() 
        // 具体实现需参考 ijkplayer 的 custom_protocol 示例，本文末尾有注释说明
        // 由于你的 so 是全功能的，可能已经内置了某些协议，只需在 whitelist 中启用
        // ===================================================================

        container.addView(textureView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))
        container.addView(snapView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                currentSurface = Surface(surface)
                isSurfaceAvailable = true
                mediaPlayer?.setSurface(currentSurface)
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                isSurfaceAvailable = false
                mediaPlayer?.setSurface(null)
                currentSurface?.release()
                currentSurface = null
                return true
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }
    }

    fun setupChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        methodChannel = MethodChannel(messenger, "ijkplayer_view_$viewId")
        methodChannel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setUrl" -> {
                val url = call.argument<String>("url")
                val decoderIndex = call.argument<Int>("decoderIndex") ?: 0
                if (url != null) {
                    // 支持动态切换解码模式
                    currentDecoderMode = decoderIndex
                    setUrl(url)
                    result.success(null)
                } else {
                    result.error("INVALID_URL", "URL is null", null)
                }
            }
            "play" -> {
                mediaPlayer?.start()
                result.success(null)
            }
            "pause" -> {
                mediaPlayer?.pause()
                result.success(null)
            }
            "stop" -> {
                mediaPlayer?.stop()
                result.success(null)
            }
            "release" -> {
                releasePlayer()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun setUrl(url: String) {
        // 截图覆盖防黑底
        if (isSurfaceAvailable && textureView.isAvailable) {
            try {
                val bitmap: Bitmap? = textureView.bitmap
                if (bitmap != null) {
                    snapView.setImageBitmap(bitmap)
                    snapView.visibility = View.VISIBLE
                }
            } catch (_: Exception) {}
        }

        // 优先复用播放器（如果解码模式未变）
        val player = mediaPlayer
        if (player != null) {
            try {
                player.stop()
                player.reset()
                configurePlayer(player, currentDecoderMode)
                player.setSurface(currentSurface)
                player.dataSource = url
                player.prepareAsync()
                return
            } catch (_: Exception) {
                releasePlayer()
            }
        }

        // 新建播放器
        val newPlayer = IjkMediaPlayer()
        mediaPlayer = newPlayer
        configurePlayer(newPlayer, currentDecoderMode)
        currentSurface?.let { newPlayer.setSurface(it) }

        try {
            newPlayer.dataSource = url
            newPlayer.prepareAsync()
        } catch (e: Exception) {
            e.printStackTrace()
            methodChannel?.invokeMethod("onError", mapOf("what" to -1, "extra" to -1))
        }
    }

    /**
     * 配置播放器参数，使其兼容尽可能多的链接格式
     * @param player 播放器实例
     * @param decoderMode 0-硬解，1-软解
     */
    private fun configurePlayer(player: IjkMediaPlayer, decoderMode: Int) {
        // ===== 1. 基础音频设置 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L) // 使用 AudioTrack，兼容性更好
        player.setAudioStreamType(AudioManager.STREAM_MUSIC)
        player.setScreenOnWhilePlaying(true)

        // ===== 2. 解码器选择 =====
        when (decoderMode) {
            0 -> {
                // 硬解：性能高，但某些编码或不标准流可能花屏
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
                // 音频强制软解，避免硬解兼容性问题
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-audio", 0L)
                // 硬解时适当丢帧以保证流畅
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 3L)
            }
            1 -> {
                // 软解：兼容性最好，但 CPU 负载高
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-audio", 0L)
                // 软解时多线程解码
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "threads", 4L)
                // 软解可更积极丢帧以防止音视频不同步
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)
            }
        }

        // ===== 3. 核心：探测参数调大，确保能识别各种格式 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024 * 1024L)        // 1MB
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 10 * 1000 * 1000L) // 10秒
        // 有些流需要更长的分析时间，但设置上限避免无限等待
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzemaxduration", 15 * 1000 * 1000L)

        // ===== 4. 网络协议白名单：尽可能全 =====
        // 包含常见协议及加密协议 (crypto)
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "protocol_whitelist",
            "file,http,https,tcp,tls,crypto,rtsp,rtp,udp,rtmp,rtmps,rtmpt,rtmpts,ftp,ftps,srt,srtp,data,zip,gopher"
        )
        // 针对 RTSP 强制使用 TCP（兼容性更好）
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")
        // 禁用 HTTP 范围请求（某些服务器不支持，会导致失败）
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "http-detect-range-support", 0L)

        // ===== 5. HTTP 请求头模拟（模拟浏览器，绕过一些限制） =====
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "user_agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        )
        // 添加常用 Referer（可根据需要动态设置）
        // player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "referer", "https://example.com")
        // 添加 Cookie（如果需要）
        // player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "cookies", "name=value")

        // ===== 6. 缓存与缓冲策略 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", 2 * 1024 * 1024L) // 2MB
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 3L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        // ===== 7. 网络超时与重连 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", 15 * 1000 * 1000L) // 15秒
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_at_eof", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_streamed", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_delay_max", 5L)

        // ===== 8. 其他优化 =====
        // 允许快速 seek
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek+flush_packets")
        // 清除 DNS 缓存（避免解析问题）
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_clear", 1L)
        // 针对 HLS 的特殊优化
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "hls_playlist_type", 0L) // 0: 自适应

        // ===== 9. 监听器 =====
        player.setOnPreparedListener { it.start() }
        player.setOnInfoListener { _, what, extra ->
            if (what == 3) { // 首帧渲染
                snapView.post {
                    snapView.visibility = View.GONE
                    snapView.setImageBitmap(null)
                }
            }
            methodChannel?.invokeMethod("onInfo", mapOf("what" to what, "extra" to extra))
            true
        }
        player.setOnErrorListener { _, what, extra ->
            snapView.post {
                snapView.visibility = View.GONE
                snapView.setImageBitmap(null)
            }
            methodChannel?.invokeMethod("onError", mapOf("what" to what, "extra" to extra))
            true
        }
    }

    fun releasePlayer() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (e: Exception) {
            e.printStackTrace()
        }
        mediaPlayer = null
        snapView.post {
            snapView.visibility = View.GONE
            snapView.setImageBitmap(null)
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        methodChannel?.setMethodCallHandler(null)
        releasePlayer()
    }

    // ========== 扩展说明：如何支持自定义加密协议（crypto://） ==========
    /*
     * 如果你的加密链接是 crypto://...，且 FFmpeg 中并未内置该协议，
     * 你需要实现一个自定义 URLProtocol，并在 IjkMediaPlayer 初始化前注册。
     * 参考 ijkplayer 官方示例：https://github.com/bilibili/ijkplayer/tree/master/android/ijkplayer-example/src/main/java/tv/danmaku/ijk/media/player/misc
     * 
     * 简略步骤：
     * 1. 在 JNI 层实现 av_register_protocol2，注册一个名为 "crypto" 的协议。
     * 2. 在 open 回调中获取密钥（可从 URL 参数或 MethodChannel 传入），
     *    在 read 回调中解密数据并返回。
     * 3. 在 init 块中调用注册函数。
     * 
     * 如果你的 so 已内置该协议，则只需在 protocol_whitelist 中添加 "crypto" 即可。
     */
}
