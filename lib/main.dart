import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // ストレージ権限をリクエスト
  await requestStoragePermissions();
  
  runApp(const MyApp());
}

Future<void> requestStoragePermissions() async {
  var status = await Permission.storage.status;
  if (!status.isGranted) {
    await [Permission.storage, Permission.manageExternalStorage].request();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Player',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

// クラスをトップレベルに移動
class MusicFile {
  final String path;
  final String name;
  final Duration duration;
  final String artist;  // artistを戻す（ソート機能のため）
  bool isSelected;

  MusicFile({
    required this.path,
    required this.name,
    required this.duration,
    this.artist = '',  // デフォルト値を設定
    this.isSelected = true,
  });
}

class _MyHomePageState extends State<MyHomePage> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  String? _currentFilePath;
  List<MusicFile> _playlist = [];
  int _currentIndex = 0;
  late SharedPreferences _prefs;
  
  // クラス内でstaticを削除
  final String defaultMusicPath = '/storage/emulated/0/Music/jumpstart';

  @override
  void initState() {
    super.initState();
    _setupAudioPlayer();
    _loadPreferences();
    _loadDefaultFolder();  // 起動時にデフォルトフォルダを読み込む
  }

  void _setupAudioPlayer() {
    _audioPlayer.onPlayerComplete.listen((_) {
      print('Song completed, playing next');
      _playNext();
    });

    _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      print('Player state changed: $state');
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });
  }

  // 設定の読み込み
  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // チェックボックスの状態を保存
  Future<void> _saveSelectionState() async {
    final selections = _playlist.asMap().map((index, music) => 
      MapEntry(music.path, music.isSelected));
    await _prefs.setString('selections', jsonEncode(selections));
  }

  // チェックボックスの状態を読み込み
  Future<void> _loadSelectionState() async {
    final selectionsJson = _prefs.getString('selections');
    if (selectionsJson != null) {
      final selections = jsonDecode(selectionsJson) as Map<String, dynamic>;
      for (var music in _playlist) {
        music.isSelected = selections[music.path] ?? true;
      }
      setState(() {});
    }
  }

  // ソートメニューを表示
  void _showSortMenu() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('並び替え'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('名前順'),
                onTap: () {
                  _sortPlaylist('name');
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('アーティスト順'),
                onTap: () {
                  _sortPlaylist('artist');
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('時間順'),
                onTap: () {
                  _sortPlaylist('duration');
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // プレイリストをソート
  void _sortPlaylist(String criteria) {
    setState(() {
      switch (criteria) {
        case 'name':
          _playlist.sort((a, b) => a.name.compareTo(b.name));
          break;
        case 'artist':
          _playlist.sort((a, b) => 
            (a.artist ?? '').compareTo(b.artist ?? ''));
          break;
        case 'duration':
          _playlist.sort((a, b) => 
            (a.duration ?? Duration.zero).compareTo(b.duration ?? Duration.zero));
          break;
      }
      // 現在再生中の曲の新しいインデックスを取得
      if (_currentFilePath != null) {
        _currentIndex = _playlist.indexWhere((file) => file.path == _currentFilePath);
      }
    });
  }

  // フォルダ選択メソッドを追加
  Future<void> _pickMusicFolder() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory == null) return;

      await _prefs.setString('lastFolder', selectedDirectory);
      await _loadMusicFromFolder(selectedDirectory);
      await _loadSelectionState();  // 追加：選択状態を復元
      setState(() {});
    } catch (e) {
      print('フォルダの選択でエラーが発生しました: $e');
    }
  }

  Future<void> _loadDefaultFolder() async {
    final lastFolder = _prefs.getString('lastFolder');
    if (lastFolder != null) {
      await _loadMusicFromFolder(lastFolder);
      await _loadSelectionState();  // 追加：選択状態を復元
      setState(() {});
    }
  }

  // 音楽ファイルを処理する補助メソッド
  Future<MusicFile?> _processMusicFile(File file) async {
    try {
      final player = AudioPlayer();
      Duration? songDuration;
      try {
        await player.setSource(DeviceFileSource(file.path));
        songDuration = await player.getDuration();
        
        String name = file.path.split(Platform.pathSeparator).last;
        return MusicFile(
          path: file.path,
          name: name,
          duration: songDuration ?? Duration.zero,
        );
      } finally {
        await player.dispose();
      }
    } catch (e) {
      print('Error processing file ${file.path}: $e');
      return null;
    }
  }

  // 有効な音楽ファイルをプレイリストに追加
  void _addValidMusicFiles(List<MusicFile?> results) {
    for (var result in results) {
      if (result != null) {
        _playlist.add(result);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Player'),
        actions: [
          // 全選択/全解除ボタンを追加
          IconButton(
            icon: const Icon(Icons.select_all),
            onPressed: () {
              final allSelected = _playlist.every((music) => music.isSelected);
              setState(() {
                for (var music in _playlist) {
                  music.isSelected = !allSelected;
                }
                _saveSelectionState();  // 状態を保存
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            onPressed: _showSortMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          // ファイル選択ボタン
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _pickAndPlayMusic,
                  child: const Text('ファイルを選択'),
                ),
                ElevatedButton(
                  onPressed: _pickMusicFolder,
                  child: const Text('フォルダを選択'),
                ),
              ],
            ),
          ),
          
          // 再生コントロール
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  iconSize: 48,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () {
                    if (_playlist.isNotEmpty) {
                      setState(() {
                        _currentIndex = (_currentIndex - 1) % _playlist.length;
                        if (_currentIndex < 0) _currentIndex = _playlist.length - 1;
                        _currentFilePath = _playlist[_currentIndex].path;
                      });
                      _playMusic();
                    }
                  },
                ),
                IconButton(
                  iconSize: 64,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () {
                    if (_isPlaying) {
                      _audioPlayer.pause();
                      setState(() => _isPlaying = false);
                    } else {
                      if (_currentFilePath != null) {
                        _playMusic();
                      }
                    }
                  },
                ),
                IconButton(
                  iconSize: 48,
                  icon: const Icon(Icons.skip_next),
                  onPressed: () {
                    if (_playlist.isNotEmpty) {
                      setState(() {
                        _currentIndex = (_currentIndex + 1) % _playlist.length;
                        _currentFilePath = _playlist[_currentIndex].path;
                      });
                      _playMusic();
                    }
                  },
                ),
              ],
            ),
          ),

          // 現在再生中の曲情報
          if (_currentFilePath != null && _playlist.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                _playlist[_currentIndex].name,
                style: const TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),

          // プレイリスト表示を更新
          Expanded(
            child: _buildPlaylist(),
          ),
        ],
      ),
    );
  }

  // ファイル選択と再生
  Future<void> _pickAndPlayMusic() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (result != null) {
        _playlist.clear();
        for (var file in result.files) {
          if (file.path != null) {
            final player = AudioPlayer();
            Duration? songDuration;
            try {
              await player.setSource(DeviceFileSource(file.path!));
              songDuration = await player.getDuration();
            } finally {
              await player.dispose();
            }

            _playlist.add(MusicFile(
              path: file.path!,
              name: file.name,
              duration: songDuration ?? Duration.zero,
            ));
          }
        }

        await _loadSelectionState();  // 保存された選択状態を読み込み

        setState(() {
          if (_playlist.isNotEmpty) {
            _currentIndex = 0;
            _currentFilePath = _playlist[0].path;
          }
        });

        await _playMusic();
      }
    } catch (e) {
      print('Error picking music: $e');
    }
  }

  Future<void> _playMusic() async {
    if (_playlist.isEmpty) return;

    // 現在の曲が選択されていない場合、次の選択された曲を探す
    if (!_playlist[_currentIndex].isSelected) {
      print('Current song is not selected, finding next selected song');
      await _playNextSong();
      return;
    }

    try {
      final currentSong = _playlist[_currentIndex];
      print('Attempting to play: ${currentSong.name}');

      await _audioPlayer.play(DeviceFileSource(currentSong.path));
      setState(() {
        _isPlaying = true;
        _currentFilePath = currentSong.path;
      });
    } catch (e) {
      print('Error playing music: $e');
      await _playNextSong();
    }
  }

  Future<void> _pauseMusic() async {
    await _audioPlayer.pause();
    setState(() {
      _isPlaying = false;
    });
  }

  Future<void> _playNext() async {
    if (_playlist.isEmpty) return;
    
    setState(() {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
      _currentFilePath = _playlist[_currentIndex].path;
    });
    
    await _playMusic();
  }

  Future<void> _playPrevious() async {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _currentFilePath = _playlist[_currentIndex].path;
      });
      await _playMusic();
    }
  }

  Future<void> _playNextSong() async {
    if (_playlist.isEmpty) return;

    int nextIndex = _currentIndex;
    int checkedCount = 0;
    
    // 選択された曲が見つかるまで、または全曲チェック済みになるまでループ
    do {
      nextIndex = (nextIndex + 1) % _playlist.length;
      checkedCount++;
      
      // 選択された曲が見つかった場合
      if (_playlist[nextIndex].isSelected) {
        setState(() {
          _currentIndex = nextIndex;
          _currentFilePath = _playlist[nextIndex].path;
        });
        await _playMusic();
        return;
      }
      
      // 全曲チェックしても選択された曲が見つからない場合
      if (checkedCount >= _playlist.length) {
        print('No selected songs in playlist');
        setState(() {
          _isPlaying = false;
        });
        return;
      }
    } while (true);
  }

  Future<void> _playPreviousSong() async {
    if (_playlist.isEmpty) return;

    int prevIndex = _currentIndex;
    int checkedCount = 0;
    
    // 選択された曲が見つかるまで、または全曲チェック済みになるまでループ
    do {
      prevIndex = (prevIndex - 1 + _playlist.length) % _playlist.length;
      checkedCount++;
      
      // 選択された曲が見つかった場合
      if (_playlist[prevIndex].isSelected) {
        setState(() {
          _currentIndex = prevIndex;
          _currentFilePath = _playlist[prevIndex].path;
        });
        await _playMusic();
        return;
      }
      
      // 全曲チェックしても選択された曲が見つからない場合
      if (checkedCount >= _playlist.length) {
        print('No selected songs in playlist');
        return;
      }
    } while (true);
  }

  // 時間表示のフォーマットを行うヘルパーメソッド
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String hours = duration.inHours > 0 ? '${twoDigits(duration.inHours)}:' : '';
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours$minutes:$seconds';
  }

  // プレイリスト表示を更新
  Widget _buildPlaylist() {
    return ListView.builder(
      itemCount: _playlist.length,
      itemBuilder: (context, index) {
        final music = _playlist[index];
        return ListTile(
          leading: Checkbox(
            value: music.isSelected,
            onChanged: (bool? value) {
              setState(() {
                music.isSelected = value ?? true;
                if (index == _currentIndex && !music.isSelected && _isPlaying) {
                  _playNextSong();
                }
                _saveSelectionState();  // 状態を保存
              });
            },
          ),
          title: Text(music.name),
          trailing: Text(_formatDuration(music.duration)),
          selected: index == _currentIndex,
          onTap: () {
            if (music.isSelected) {
              setState(() {
                _currentIndex = index;
                _currentFilePath = music.path;
              });
              _playMusic();
            }
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadMusicFromFolder(String path) async {
    try {
      Directory directory = Directory(path);
      List<FileSystemEntity> files = directory.listSync(recursive: true);
      
      _playlist.clear();
      
      for (var file in files) {
        if (file is File) {
          String filePath = file.path.toLowerCase();
          if (filePath.endsWith('.mp3') || 
              filePath.endsWith('.m4a') || 
              filePath.endsWith('.wav') || 
              filePath.endsWith('.aac')) {
            
            final player = AudioPlayer();
            Duration? songDuration;
            try {
              await player.setSource(DeviceFileSource(file.path));
              songDuration = await player.getDuration();
            } finally {
              await player.dispose();
            }

            String name = file.path.split(Platform.pathSeparator).last;
            _playlist.add(MusicFile(
              path: file.path,
              name: name,
              duration: songDuration ?? Duration.zero,
            ));
          }
        }
      }

      setState(() {
        if (_playlist.isNotEmpty) {
          _currentIndex = 0;
          _currentFilePath = _playlist[0].path;
        }
      });

      if (_playlist.isNotEmpty) {
        await _playMusic();
      }
    } catch (e) {
      print('Error loading music from folder: $e');
    }
  }
}

