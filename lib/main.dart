import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'package:audio_session/audio_session.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await requestStoragePermissions();
  
  // AudioSessionの設定
  final session = await AudioSession.instance;
  if (Platform.isIOS) {
    await session.configure(const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidWillPauseWhenDucked: true,
    ));
  }
  
  runApp(const MyApp());
}

Future<void> requestStoragePermissions() async {
  if (Platform.isAndroid) {
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '安定版ミュージックプレイヤー',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const MyHomePage(),
    );
  }
}

class MusicFile {
  final String path;
  final String name;
  final Duration duration;
  bool isSelected;

  MusicFile({
    required this.path,
    required this.name,
    required this.duration,
    this.isSelected = true,
  });
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final List<StreamSubscription> _subscriptions = [];
  bool _isPlaying = false;
  bool _isLoading = false;
  String? _currentFilePath;
  List<MusicFile> _playlist = [];
  int _currentIndex = 0;
  late SharedPreferences _prefs;
  final _playerStateLock = Lock(); // 排他制御用ロック

  @override
  void initState() {
    super.initState();
    _initPlayer();
    _loadPreferences().then((_) => _loadLastSession());
    _setupBackgroundPlayback();
  }

  void _initPlayer() {
    _subscriptions.addAll([
      _audioPlayer.onPlayerStateChanged.listen(_handlePlayerStateChange),
      _audioPlayer.onPositionChanged.listen(_handlePositionChange),
      _audioPlayer.onDurationChanged.listen(_handleDurationChange),
      _audioPlayer.onPlayerComplete.listen(_handlePlaybackComplete),
    ]);
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> _loadLastSession() async {
    final lastFolder = _prefs.getString('lastFolder');
    if (lastFolder != null && await Directory(lastFolder).exists()) {
      await _loadMusicFromFolder(lastFolder);
      await _loadSelectionState();
    }
  }

  // プレイヤー状態管理（排他制御付き）
  Future<void> _handlePlayerStateChange(PlayerState state) async {
    if (!mounted) return;
    
    await _playerStateLock.synchronized(() async {
      if (state == PlayerState.stopped && !_isLoading) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_audioPlayer.state == PlayerState.stopped) {
          await _playNextSong();
        }
      }
      setState(() => _isPlaying = state == PlayerState.playing);
    });
  }

  void _handlePositionChange(Duration position) {
    // 再生位置表示用（必要に応じて実装）
  }

  void _handleDurationChange(Duration duration) {
    // 曲の長さ更新用
  }

  void _handlePlaybackComplete(void _) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 300));
      if (_audioPlayer.state == PlayerState.completed) {
        await _playNextSong();
      }
    });
  }

  Future<void> _playMusic() async {
    if (_playlist.isEmpty || _isLoading) return;
    
    _isLoading = true;
    try {
      final currentSong = _playlist[_currentIndex];
      if (!currentSong.isSelected) {
        await _playNextSong();
        return;
      }

      // 再生リセット処理を明確化
      await _audioPlayer.stop();
      await _audioPlayer.setSource(DeviceFileSource(currentSong.path));
      await _audioPlayer.resume();

      setState(() => _currentFilePath = currentSong.path);
      await _prefs.setInt('lastIndex', _currentIndex);
    } catch (e) {
      print('再生エラー: $e');
      await _playNextSong();
    } finally {
      _isLoading = false;
    }
  }

  Future<void> _playNextSong() async {
    if (_playlist.isEmpty) return;

    int startIndex = _currentIndex;
    int nextIndex = _currentIndex;
    int loopCount = 0;

    do {
      nextIndex = (nextIndex + 1) % _playlist.length;
      loopCount++;

      if (loopCount > _playlist.length) {
        await _audioPlayer.stop();
        setState(() => _isPlaying = false);
        return;
      }

      if (_playlist[nextIndex].isSelected) {
        setState(() => _currentIndex = nextIndex);
        await _playMusic();
        return;
      }

    } while (nextIndex != startIndex);
  }

  Future<void> _playPreviousSong() async {
    if (_playlist.isEmpty) return;

    int originalIndex = _currentIndex;
    int prevIndex = _currentIndex;
    int checkedCount = 0;

    while (checkedCount < _playlist.length) {
      prevIndex = (prevIndex - 1 + _playlist.length) % _playlist.length;
      checkedCount++;

      if (_playlist[prevIndex].isSelected) {
        _currentIndex = prevIndex;
        await _playMusic();
        return;
      }
    }

    if (originalIndex == _currentIndex) {
      await _audioPlayer.stop();
      setState(() => _isPlaying = false);
    }
  }

  Future<void> _loadMusicFromFolder(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return;

      _playlist = await dir.list()
        .asyncMap((file) => _processFile(file))
        .where((music) => music != null)
        .cast<MusicFile>()
        .toList();

      if (_playlist.isNotEmpty) {
        _currentIndex = _prefs.getInt('lastIndex') ?? 0;
        _currentIndex = _currentIndex.clamp(0, _playlist.length - 1);
        _currentFilePath = _playlist[_currentIndex].path;
      }

      setState(() {});
      await _prefs.setString('lastFolder', path);
    } catch (e) {
      print('フォルダ読み込みエラー: $e');
    }
  }

  Future<MusicFile?> _processFile(FileSystemEntity file) async {
    if (file is! File) return null;
    if (!['.mp3', '.m4a', '.wav'].any(file.path.toLowerCase().endsWith)) return null;

    final player = AudioPlayer();
    try {
      await player.setSource(DeviceFileSource(file.path));
      final duration = await player.getDuration() ?? Duration.zero;
      return MusicFile(
        path: file.path,
        name: _getFileName(file.path),
        duration: duration,
      );
    } catch (e) {
      print('ファイル処理エラー: ${file.path} - $e');
      return null;
    } finally {
      await player.dispose();
    }
  }

  String _getFileName(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安定版プレイヤー'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _pickMusicFolder,
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            onPressed: _showSortMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildPlayerControls(),
          Expanded(child: _buildPlaylist()),
        ],
      ),
    );
  }

  Widget _buildPlayerControls() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Text(
            _currentFilePath != null 
              ? _getFileName(_currentFilePath!)
              : '曲を選択してください',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 40,
                onPressed: _playPreviousSong,
              ),
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                iconSize: 64,
                onPressed: _togglePlayback,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 40,
                onPressed: _playNextSong,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      if (_currentFilePath == null && _playlist.isNotEmpty) {
        _currentIndex = 0;
        _currentFilePath = _playlist[0].path;
      }
      await _playMusic();
    }
  }

  Widget _buildPlaylist() {
    return ListView.builder(
      itemCount: _playlist.length,
      itemBuilder: (context, index) {
        final music = _playlist[index];
        return ListTile(
          leading: Checkbox(
            value: music.isSelected,
            onChanged: (value) => _toggleSelection(index, value ?? true),
          ),
          title: Text(music.name),
          subtitle: Text(_formatDuration(music.duration)),
          selected: index == _currentIndex,
          onTap: () => _selectTrack(index),
        );
      },
    );
  }

  void _toggleSelection(int index, bool value) {
    setState(() => _playlist[index].isSelected = value);
    _saveSelectionState();
    if (index == _currentIndex && !value && _isPlaying) {
      _playNextSong();
    }
  }

  Future<void> _selectTrack(int index) async {
    if (!_playlist[index].isSelected) return;
    
    setState(() => _currentIndex = index);
    _currentFilePath = _playlist[index].path;
    await _playMusic();
  }

  String _formatDuration(Duration d) => 
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _pickMusicFolder() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path != null) await _loadMusicFromFolder(path);
    } catch (e) {
      print('フォルダ選択エラー: $e');
    }
  }

  void _showSortMenu() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('並び替え'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSortButton('名前順', () => _sortPlaylist((a, b) => a.name.compareTo(b.name))),
            _buildSortButton('再生時間', () => _sortPlaylist((a, b) => a.duration.compareTo(b.duration))),
          ],
        ),
      ),
    );
  }

  ListTile _buildSortButton(String label, VoidCallback onPressed) {
    return ListTile(
      title: Text(label),
      onTap: () {
        onPressed();
        Navigator.pop(context);
      },
    );
  }

  void _sortPlaylist(Comparator<MusicFile> comparator) {
    setState(() {
      _playlist.sort(comparator);
      _currentIndex = _playlist.indexWhere((m) => m.path == _currentFilePath);
    });
  }

  Future<void> _saveSelectionState() async {
    final selections = {for (var m in _playlist) m.path: m.isSelected};
    await _prefs.setString('selections', jsonEncode(selections));
  }

  Future<void> _loadSelectionState() async {
    final json = _prefs.getString('selections');
    if (json == null) return;

    final selections = Map<String, dynamic>.from(jsonDecode(json));
    for (var music in _playlist) {
      music.isSelected = selections[music.path] ?? true;
    }
    setState(() {});
  }

  Future<void> _setupBackgroundPlayback() async {
    // AudioPlayersの設定
    await _audioPlayer.setReleaseMode(ReleaseMode.stop);
    
    if (Platform.isAndroid) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
      
      await session.setActive(true);
    }
    
    // イベントリスナーの設定
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        _playNextSong();
      }
    });
  }
}

class Lock {
  bool _isLocked = false;
  Future<void> synchronized(Future<void> Function() task) async {
    while (_isLocked) await Future.delayed(const Duration(milliseconds: 10));
    _isLocked = true;
    try {
      await task();
    } finally {
      _isLocked = false;
    }
  }
}
