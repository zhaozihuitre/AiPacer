import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 音声入力。Android は端末の SpeechRecognizer(多くの機種で Google 音声サービス)、
/// Web はブラウザの Web Speech API を使う。
abstract class VoiceInput {
  /// 認識を始める。使えない(マイク権限が無い / 音声サービスが無い)ときは false。
  /// [onResult] は途中結果のたびに呼ぶ。`text` はこの入力で認識した全文。
  /// [onDone] は入力の終了(無音 / 手動停止 / エラー)で 1 回だけ呼ぶ。
  Future<bool> start({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String? error) onDone,
  });

  Future<void> stop();
}

/// 認識エンジン(1 区切り分の聞き取り)。[ContinuousVoiceInput] から使う。テストではフェイクに替える。
abstract class SpeechEngine {
  /// 初めの 1 回だけ呼ぶ。[onStatus] は 'listening' / 'notListening' / 'done'、
  /// [onError] は 'error_no_match' などのエラー名。
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error) onError,
  });

  Future<void> listen({
    required String localeId,
    required void Function(String words, bool isFinal) onResult,
  });

  Future<void> stop();
}

/// 話していないことを表すエラー(エラーとしては扱わない)。
const silenceErrors = {'error_no_match', 'error_speech_timeout'};

/// 途中で間を置いても聞き取りを続ける音声入力。
///
/// Android の認識サービスは、話が 1〜2 秒途切れると自分で聞き取りを終える
/// (`pauseFor` / EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS は Android 13 以降ほぼ効かない)。
/// そこで、1 区切りで何か認識できたら自動で次の区切りを始め、結果をつなげる。
/// 終わるのは:利用者が止めたとき / 次の区切りで何も話さなかったとき / [maxDuration] を超えたとき。
class ContinuousVoiceInput implements VoiceInput {
  ContinuousVoiceInput({
    SpeechEngine? engine,
    this.localeId = 'ja_JP',
    this.maxDuration = const Duration(seconds: 60),
    this.restartDelay = const Duration(milliseconds: 250),
    DateTime Function()? clock,
  })  : _engine = engine ?? SpeechToTextEngine(),
        _clock = clock ?? DateTime.now;

  final SpeechEngine _engine;
  final String localeId;
  final Duration maxDuration;
  final Duration restartDelay;
  final DateTime Function() _clock;

  bool _ready = false;

  /// 入力ごとに +1。古い入力のコールバックや再開を無視するために使う。
  int _session = 0;
  bool _active = false;
  bool _stopping = false;
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 確定した区切りのテキストと、いま聞いている区切りのテキスト。
  final List<String> _segments = [];
  String _current = '';
  bool _currentFinal = false;
  bool _segmentEnded = false;

  void Function(String text, bool isFinal)? _onResult;
  void Function(String? error)? _onDone;

  String get _joiner => localeId.startsWith('ja') ? '' : ' ';

  String _fullText() =>
      [..._segments, if (_current.isNotEmpty) _current].join(_joiner);

  void _finish(String? error) {
    if (!_active) return;
    _active = false;
    _session++;
    final done = _onDone;
    _onDone = null;
    _onResult = null;
    done?.call(error);
  }

  void _handleStatus(String status) {
    if (!_active || status != SpeechToText.doneStatus) return;
    _endSegment();
  }

  void _handleError(String error) {
    if (!_active) return;
    if (silenceErrors.contains(error)) {
      // この区切りで何も話さなかった = 話し終わった
      _segmentEnded = true;
      _finish(null);
    } else {
      _finish(error);
    }
  }

  /// 1 区切りが終わった。何か認識できていて時間も残っていれば次の区切りを始める。
  void _endSegment() {
    if (_segmentEnded) return;
    _segmentEnded = true;
    final heard = _current.isNotEmpty;
    if (heard) {
      _segments.add(_current);
      _current = '';
    }
    if (_stopping || !heard || _clock().difference(_startedAt) >= maxDuration) {
      _finish(null);
      return;
    }
    final session = _session;
    Future<void>.delayed(restartDelay, () {
      if (session == _session && _active && !_stopping) _listenSegment();
    });
  }

  Future<void> _listenSegment() async {
    _segmentEnded = false;
    _current = '';
    _currentFinal = false;
    final session = _session;
    await _engine.listen(
      localeId: localeId,
      onResult: (words, isFinal) {
        if (session != _session || !_active) return;
        _current = words;
        _currentFinal = isFinal;
        _onResult?.call(_fullText(), isFinal);
      },
    );
  }

  @override
  Future<bool> start({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String? error) onDone,
  }) async {
    if (!_ready) {
      _ready = await _engine.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
      );
      if (!_ready) return false;
    }
    _session++;
    _active = true;
    _stopping = false;
    _startedAt = _clock();
    _segments.clear();
    _onResult = onResult;
    _onDone = onDone;
    await _listenSegment();
    return true;
  }

  @override
  Future<void> stop() async {
    if (!_active) return;
    _stopping = true;
    await _engine.stop();
    // エンジンが done を返さないことがあるので、ここでも終える(_finish は 1 回だけ有効)
    if (_currentFinal || _current.isNotEmpty) {
      _segments.add(_current);
      _current = '';
    }
    _finish(null);
  }
}

/// `speech_to_text` を使うエンジン。
class SpeechToTextEngine implements SpeechEngine {
  final SpeechToText _speech = SpeechToText();

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error) onError,
  }) {
    return _speech.initialize(
      onStatus: onStatus,
      onError: (SpeechRecognitionError e) => onError(e.errorMsg),
    );
  }

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String words, bool isFinal) onResult,
  }) {
    return _speech.listen(
      onResult: (SpeechRecognitionResult r) =>
          onResult(r.recognizedWords, r.finalResult),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        cancelOnError: true,
        // 1 区切りの上限。区切りをつなげた全体の上限は ContinuousVoiceInput.maxDuration
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();
}
