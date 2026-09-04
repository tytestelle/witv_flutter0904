package com.whyun.witv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.AudioManager
import android.net.Uri
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer
import java.net.URL

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
    private var currentDecoderMode = 0
    private var retryCount = 0
    private val maxRetries = 1

    // 存储当前应用的额外请求头
    private var currentHeaders: Map<String, String>? = null
    private val contextRef = context

    init {
        IjkMediaPlayer.loadLibrariesOnce(null)

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
                val headers = call.argument<Map<String, String>>("headers") // 接收 headers
                if (url != null) {
                    currentDecoderMode = decoderIndex
                    currentHeaders = headers
                    retryCount = 0
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

    /**
     * URL 规范化
     */
    private fun normalizeUrl(rawUrl: String): String {
        var normalized = rawUrl.trim()
        val specialRegex = Regex("""^(\d+):(\d+)/(.*)$""")
        val match = specialRegex.find(normalized)
        if (match != null) {
            val host = match.groupValues[2]
            val path = match.groupValues[3]
            normalized = "http://$host/$path"
        } else {
            val hasProtocol = normalized.startsWith("http://") ||
                    normalized.startsWith("https://") ||
                    normalized.startsWith("rtmp://") ||
                    normalized.startsWith("rtsp://") ||
                    normalized.startsWith("file://") ||
                    normalized.startsWith("crypto://") ||
                    normalized.startsWith("ftp://")
            if (!hasProtocol) {
                normalized = "http://$normalized"
            }
        }
        return normalized
    }

    private fun getDomainFromUrl(url: String): String? {
        return try {
            val uri = URL(url)
            "${uri.protocol}://${uri.host}${if (uri.port > 0 && uri.port != 80 && uri.port != 443) ":" + uri.port else ""}"
        } catch (_: Exception) {
            null
        }
    }

    fun setUrl(rawUrl: String) {
        val url = normalizeUrl(rawUrl)

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

        // 复用播放器（注意：需要重新设置headers，因为reset会清空）
        val player = mediaPlayer
        if (player != null) {
            try {
                player.stop()
                player.reset()
                configurePlayer(player, currentDecoderMode, url)
                player.setSurface(currentSurface)
                // 使用带 headers 的 setDataSource
                applyDataSource(player, url)
                player.prepareAsync()
                return
            } catch (_: Exception) {
                releasePlayer()
            }
        }

        // 新建播放器
        val newPlayer = IjkMediaPlayer()
        mediaPlayer = newPlayer
        configurePlayer(newPlayer, currentDecoderMode, url)
        currentSurface?.let { newPlayer.setSurface(it) }

        try {
            applyDataSource(newPlayer, url)
            newPlayer.prepareAsync()
        } catch (e: Exception) {
            e.printStackTrace()
            if (retryCount < maxRetries) {
                retryCount++
                val newMode = if (currentDecoderMode == 0) 1 else 0
                currentDecoderMode = newMode
                releasePlayer()
                setUrl(rawUrl) // 递归重试
            } else {
                methodChannel?.invokeMethod("onError", mapOf("what" to -1, "extra" to -1))
            }
        }
    }

    /**
     * 根据是否有 headers，选择不同的 setDataSource 方法
     */
    private fun applyDataSource(player: IjkMediaPlayer, url: String) {
        val headers = currentHeaders
        if (headers != null && headers.isNotEmpty()) {
            // 使用带 headers 的重载
            player.setDataSource(contextRef, Uri.parse(url), headers)
        } else {
            // 普通方式
            player.dataSource = url
        }
    }

    /**
     * 配置播放器参数（同之前，保持不变，但确保 Referer 也通过 headers 方式可覆盖）
     */
    private fun configurePlayer(player: IjkMediaPlayer, decoderMode: Int, url: String) {
        // ===== 基础音频 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
        player.setAudioStreamType(AudioManager.STREAM_MUSIC)
        player.setScreenOnWhilePlaying(true)

        // ===== 解码器 =====
        when (decoderMode) {
            0 -> {
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-audio", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 3L)
            }
            1 -> {
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-audio", 0L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "threads", 4L)
                player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)
            }
        }

        // ===== 探测参数 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024 * 1024L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 10 * 1000 * 1000L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzemaxduration", 15 * 1000 * 1000L)

        // ===== 网络协议 =====
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "protocol_whitelist",
            "file,http,https,tcp,tls,crypto,rtsp,rtp,udp,rtmp,rtmps,rtmpt,rtmpts,ftp,ftps,srt,srtp,data,zip,gopher"
        )
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "http-detect-range-support", 0L)

        // ===== 请求头模拟（基础） =====
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "user_agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        )
        // Referer：自动添加，但可通过 headers 覆盖
        getDomainFromUrl(url)?.let { domain ->
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "referer", domain)
        }

        // ===== 缓冲与重连 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", 4 * 1024 * 1024L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 3L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", 15 * 1000 * 1000L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_at_eof", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_streamed", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_delay_max", 5L)

        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek+flush_packets")
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_clear", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "enable-accurate-seek", 1L)

        // ===== 监听器 =====
        player.setOnPreparedListener { it.start() }
        player.setOnInfoListener { _, what, extra ->
            if (what == 3) {
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
        } catch (_: Exception) {}
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
}
