import 'package:flutter_tts/flutter_tts.dart';

/// 音声読み上げ。端末の TTS(Android は多くの機種で Google の音声合成、Web はブラウザの
/// SpeechSynthesis)を使う。外部サービスには送らない。
abstract class SpeechOutput {
  /// 読み上げを始める。端末に TTS が無い・日本語が使えないときは false。
  /// [onProgress] は読み終えた位置(0.0〜1.0)、[onDone] は終了(最後まで / 停止 / エラー)で 1 回だけ呼ぶ。
  Future<bool> speak(
    String text, {
    required void Function(double progress) onProgress,
    required void Function() onDone,
  });

  Future<void> stop();
}

/// 画面で使う読み上げの実装。テストでは [set] でフェイクに差し替える。
class SpeechOutputLocator {
  static SpeechOutput? _instance;

  static SpeechOutput get instance => _instance ??= FlutterTtsSpeechOutput();

  static void set(SpeechOutput output) => _instance = output;

  static void reset() => _instance = null;
}

/// Android の TextToSpeech が受け付ける長さ(getMaxSpeechInputLength = 4000)より少し短くする。
const _maxLength = 3900;

/// 回答テキストを読み上げ用に整える。箇条書きの「・」や Markdown 記号を外し、改行を句点にする。
String narrationText(String text) {
  final lines = text
      .split('\n')
      .map((l) => l
          .trim()
          .replaceFirst(RegExp(r'^[・•\-*]\s*'), '')
          .replaceAll(RegExp(r'[*#`]'), '')
          .trim())
      .where((l) => l.isNotEmpty)
      .map((l) => RegExp(r'[。！？!?:：]$').hasMatch(l) ? l : '$l。');
  final joined = lines.join();
  return joined.length > _maxLength ? joined.substring(0, _maxLength) : joined;
}

class FlutterTtsSpeechOutput implements SpeechOutput {
  FlutterTtsSpeechOutput({this.language = 'ja-JP'});

  final String language;
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  int _length = 1;
  void Function(double)? _onProgress;
  void Function()? _onDone;

  void _finish() {
    final done = _onDone;
    _onDone = null;
    _onProgress = null;
    done?.call();
  }

  Future<bool> _init() async {
    if (_ready) return true;
    final available = await _tts.isLanguageAvailable(language);
    if (available != true) return false;
    await _tts.setLanguage(language);
    await _tts.setSpeechRate(0.5); // Android の標準速度(1.0 だと速すぎる)
    _tts.setProgressHandler((_, __, end, ___) {
      _onProgress?.call((end / _length).clamp(0.0, 1.0));
    });
    _tts.setCompletionHandler(() {
      _onProgress?.call(1);
      _finish();
    });
    _tts.setCancelHandler(_finish);
    _tts.setErrorHandler((_) => _finish());
    _ready = true;
    return true;
  }

  @override
  Future<bool> speak(
    String text, {
    required void Function(double progress) onProgress,
    required void Function() onDone,
  }) async {
    if (!await _init()) return false;
    // 前の読み上げが残っていれば、その終了通知を先に出してから始める
    if (_onDone != null) {
      await _tts.stop();
      _finish();
    }
    final speech = narrationText(text);
    if (speech.isEmpty) return false;
    _length = speech.length;
    _onProgress = onProgress;
    _onDone = onDone;
    final result = await _tts.speak(speech);
    if (result != 1 && result != true) {
      _finish();
      return false;
    }
    return true;
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    _finish();
  }
}
