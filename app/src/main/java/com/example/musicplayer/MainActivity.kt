class MainActivity : AppCompatActivity() {
    private var mediaPlayer: MediaPlayer? = null
    private var currentSongIndex = 0
    private var songs = mutableListOf<Song>()
    private var isPlaying = false
    
    data class Song(
        val id: Long,
        val title: String,
        val artist: String,
        val path: String,
        val duration: Long
    )

    companion object {
        private const val TAG = "MusicPlayer"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        
        // 権限チェックと取得
        if (checkPermission()) {
            loadSongs()
        } else {
            requestPermission()
        }
        
        setupButtons()
    }
    
    private fun setupButtons() {
        findViewById<ImageButton>(R.id.playButton).setOnClickListener {
            if (mediaPlayer?.isPlaying == true) {
                pauseMusic()
            } else {
                playMusic()
            }
        }
        
        findViewById<ImageButton>(R.id.nextButton).setOnClickListener {
            playNextSong()
        }
        
        findViewById<ImageButton>(R.id.prevButton).setOnClickListener {
            playPreviousSong()
        }
        
        findViewById<Button>(R.id.sortButton).setOnClickListener {
            showSortDialog()
        }
    }
    
    private fun loadSongs() {
        Log.d(TAG, "Starting to load songs")
        val musicResolver = contentResolver
        val musicUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val selection = MediaStore.Audio.Media.IS_MUSIC + "!= 0"
        val sortOrder = MediaStore.Audio.Media.TITLE + " ASC"
        
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DURATION
        )
        
        try {
            musicResolver.query(musicUri, projection, selection, null, sortOrder)?.use { cursor ->
                if (cursor.count == 0) {
                    Log.w(TAG, "No music files found")
                    Toast.makeText(this, "音楽ファイルが見つかりません", Toast.LENGTH_LONG).show()
                    return
                }
                
                while (cursor.moveToNext()) {
                    val path = cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA))
                    // ファイルの存在確認
                    if (!File(path).exists()) {
                        Log.w(TAG, "File does not exist: $path")
                        continue
                    }
                    
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID))
                    val title = cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE))
                    val artist = cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST))
                    val duration = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION))
                    
                    songs.add(Song(id, title, artist, path, duration))
                    Log.d(TAG, "Added song: $title ($path)")
                }
            }
            
            Log.d(TAG, "Total songs loaded: ${songs.size}")
            if (songs.isNotEmpty()) {
                // 最初の曲のパスを確認
                val firstSong = songs[0]
                Log.d(TAG, "First song path exists: ${File(firstSong.path).exists()}")
                Log.d(TAG, "First song details: ${firstSong.title} - ${firstSong.path}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error loading songs", e)
            Toast.makeText(this, "音楽ファイルの読み込みエラー: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }
    
    private fun setupMediaPlayer() {
        mediaPlayer?.setOnCompletionListener {
            // 曲が終わったら次の曲を自動再生
            playNextSong()
        }
    }
    
    private fun playMusic() {
        if (songs.isEmpty()) {
            Log.d(TAG, "No songs available")
            return
        }

        try {
            val currentSong = songs[currentSongIndex]
            Log.d(TAG, "Attempting to play: ${currentSong.title}")

            // 既存のMediaPlayerをクリーンアップ
            releaseMediaPlayer()
            
            // 新しいMediaPlayerインスタンスを作成
            mediaPlayer = MediaPlayer().apply {
                setOnPreparedListener { mp ->
                    Log.d(TAG, "MediaPlayer prepared, starting playback")
                    mp.start()
                    isPlaying = true
                    updatePlaybackState()
                }
                
                setOnCompletionListener { mp ->
                    Log.d(TAG, "Song completed naturally")
                    isPlaying = false
                    // 次の曲を再生する前に少し待つ
                    Handler(Looper.getMainLooper()).postDelayed({
                        playNextSong()
                    }, 500)
                }

                setOnErrorListener { mp, what, extra ->
                    Log.e(TAG, "MediaPlayer Error: what=$what extra=$extra")
                    isPlaying = false
                    releaseMediaPlayer()
                    Handler(Looper.getMainLooper()).postDelayed({
                        playNextSong()
                    }, 1000)
                    true
                }

                try {
                    setDataSource(currentSong.path)
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .build()
                    )
                    prepare()
                    Log.d(TAG, "MediaPlayer setup completed for: ${currentSong.title}")
                } catch (e: Exception) {
                    Log.e(TAG, "Error in playback setup", e)
                    releaseMediaPlayer()
                    Handler(Looper.getMainLooper()).postDelayed({
                        playNextSong()
                    }, 1000)
                }
            }
            
            updateSongInfo()
            
        } catch (e: Exception) {
            Log.e(TAG, "Fatal error in playMusic", e)
            Toast.makeText(this, "再生エラー: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }
    
    private fun releaseMediaPlayer() {
        mediaPlayer?.let { player ->
            try {
                if (player.isPlaying) {
                    player.stop()
                }
                player.reset()
                player.release()
                Log.d(TAG, "MediaPlayer released successfully")
            } catch (e: Exception) {
                Log.e(TAG, "Error releasing MediaPlayer", e)
            } finally {
                mediaPlayer = null
                isPlaying = false
            }
        }
    }

    private fun updatePlaybackState() {
        runOnUiThread {
            findViewById<ImageButton>(R.id.playButton).setImageResource(
                if (isPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play
            )
        }
    }

    private fun playNextSong() {
        if (songs.isEmpty()) return
        currentSongIndex = (currentSongIndex + 1) % songs.size
        Log.d(TAG, "Moving to next song, index: $currentSongIndex")
        playMusic()
    }
    
    private fun playPreviousSong() {
        if (songs.isEmpty()) return
        currentSongIndex = if (currentSongIndex > 0) currentSongIndex - 1 else songs.size - 1
        playMusic()
    }
    
    private fun pauseMusic() {
        mediaPlayer?.let { player ->
            try {
                if (player.isPlaying) {
                    player.pause()
                    isPlaying = false
                    updatePlaybackState()
                    Log.d(TAG, "Playback paused")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error pausing playback", e)
            }
        }
    }
    
    private fun updateSongInfo() {
        if (songs.isEmpty()) return
        val currentSong = songs[currentSongIndex]
        findViewById<TextView>(R.id.songTitleText).text = 
            "${currentSong.title}\n${currentSong.artist}"
        Log.d(TAG, "UI updated for: ${currentSong.title}")
    }
    
    private fun showSortDialog() {
        val options = arrayOf("タイトル順", "アーティスト順", "時間順")
        AlertDialog.Builder(this)
            .setTitle("ソート方法を選択")
            .setItems(options) { _, which ->
                when (which) {
                    0 -> songs.sortBy { it.title }
                    1 -> songs.sortBy { it.artist }
                    2 -> songs.sortBy { it.duration }
                }
                currentSongIndex = 0
                updateSongInfo()
            }
            .show()
    }
    
    private fun checkPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_MEDIA_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }
    
    private fun requestPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.READ_MEDIA_AUDIO),
                1
            )
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                1
            )
        }
    }
    
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            1 -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    Log.d(TAG, "Permission granted, loading songs")
                    loadSongs()
                } else {
                    Log.w(TAG, "Permission denied")
                    Toast.makeText(this, "ストレージへのアクセス権限が必要です", Toast.LENGTH_LONG).show()
                }
            }
        }
    }
    
    override fun onDestroy() {
        Log.d(TAG, "Activity destroying")
        releaseMediaPlayer()
        super.onDestroy()
    }
} 