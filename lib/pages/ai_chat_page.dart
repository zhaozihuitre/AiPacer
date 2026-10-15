import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../models/ai_chat.dart';
import '../services/ai_assistant_service.dart';
import '../services/auth_service.dart';
import '../services/photo_picker.dart';
import '../services/session_store.dart';
import '../services/speech_output_service.dart';
import '../services/voice_input_service.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/tech_ui.dart';
import 'barcode_scan_page.dart';
import 'login_page.dart';

/// AI PACER のメイン画面(ログイン後はこの画面だけ)。
///
/// 回答は [AiAssistant] から [AiEvent] のストリームで受け取り、届いた分から表示する。
/// 既定の回答元は [AiAssistantLocator.instance](本番の mdlink-mobile-app-agent)。
/// 企業・店舗は選ばない(agent には送らず、店舗は質問の中で指定してもらう)。
/// 音声入力は [VoiceInput](既定は Google 音声認識)。認識結果は入力欄に入れ、送信は利用者が押す。
/// 音声読み上げは [SpeechOutput](既定は端末の TTS)。回答が届き終わると自動で読み上げる(上部の 🔊 でオフにできる)。
class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    this.assistant,
    this.voiceInput,
    this.speechOutput,
  });

  /// null なら [AiAssistantLocator.instance]。テストでは差し替える。
  final AiAssistant? assistant;

  /// null なら [ContinuousVoiceInput](間を置いても聞き続ける)。テストではフェイクを渡す。
  final VoiceInput? voiceInput;

  /// null なら [SpeechOutputLocator.instance](端末の TTS)。
  final SpeechOutput? speechOutput;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

/// 質問に付けた写真。送ったばかりのものは手元のバイト列、履歴から開いたものは id で持つ。
class _Photo {
  const _Photo.local(Uint8List this.bytes) : id = null;
  const _Photo.remote(String this.id) : bytes = null;

  final Uint8List? bytes;
  final String? id;
}

class _ChatEntry {
  _ChatEntry.user(
    this.question,
    this.at, {
    this.viaVoice = false,
    this.photos = const [],
  })  : isUser = true,
        streaming = false;
  _ChatEntry.ai(
    this.at, {
    String text = '',
    this.streaming = true,
    List<AiChart> charts = const [],
    List<String> suggestions = const [],
  })  : isUser = false,
        question = null,
        viaVoice = false,
        photos = const [] {
    this.text.write(text);
    this.charts.addAll(charts);
    this.suggestions.addAll(suggestions);
  }

  final bool isUser;
  final String? question;
  final DateTime at;
  final bool viaVoice;

  /// 質問に付けた写真。
  final List<_Photo> photos;

  /// AI の回答テキスト(受信中は届いた分だけ)。
  final StringBuffer text = StringBuffer();

  /// 回答に付いたグラフ(show_chart)。
  final List<AiChart> charts = [];

  /// 「続けて聞く」質問候補(suggest_questions)。最新の回答の下にだけ出す。
  final List<String> suggestions = [];

  /// デモ用の構造化された回答。あればこちらを表示する。
  AiReply? reply;

  /// 実行中のデータ取得(ツール名)。null なら取得中ではない。
  String? runningTool;
  bool streaming;

  AiReply get displayReply =>
      reply ?? AiReply(text: text.toString(), answeredAt: at);
}

/// 最初の質問候補。店舗を選ばないので、店舗を含めた質問にする。
/// データは前日までなので「本日」は使わない。
const _initialSuggestions = [
  (
    icon: Icons.show_chart_rounded,
    title: '売上の推移',
    question: '67番店舗の今月の日別売上の推移は？',
  ),
  (
    icon: Icons.donut_large_rounded,
    title: '部門別の達成率',
    question: '67番店舗の昨日の部門別の予算達成率は？',
  ),
  (
    icon: Icons.compare_arrows_rounded,
    title: '予算・昨年比較',
    question: '67番店舗の昨日の売上を予算・昨年と比べて',
  ),
  (
    icon: Icons.radar_rounded,
    title: '商圏・競合',
    question: '67番店舗の商圏の競合店を教えて',
  ),
];

/// 何ができるかを示すタグ。
const _capabilities = ['売上', '予算', '在庫', '棚割', '顧客', '商圏', '競合'];

/// ツール名 → 取得中に表示する文言。
const _toolLabels = {
  'get_stores': '店舗情報',
  'get_product_categories': '商品カテゴリ',
  'get_makers': 'メーカー情報',
  'get_wholesalers': '卸情報',
  'calculate_trial_date': 'TRIAL 暦',
  'get_store_sales_progress': '店舗の売上',
  'get_daily_sales_progress': '月間の売上進捗',
  'get_department_daily_status': '部門別の達成状況',
  'search_products': '商品情報',
  'get_store_product_sales': '商品の売上',
  'get_data_date_range': 'データの期間',
  'get_store_product_inventory_and_sales_history': '在庫・発注の履歴',
  'get_current_shelf_layout': '棚割',
  'get_store_product_daily_stock': '日別の在庫',
  'search_shelf_update_instructions_by_jans': '棚替えの予定',
  'search_shelf_update_instructions_by_shelf_name': '棚替えの予定',
  'get_shelf_update_instructions': '棚替えの内容',
  'get_customer_count': '購入客数',
  'analyze_customer_attributes': '購入者の属性',
  'analyze_repeat_purchase': 'リピート購入',
  'retailmap_store_trade_area_available': '商圏の種類',
  'retailmap_store_trade_area_census': '商圏の人口・世帯',
  'retailmap_store_trade_area_data': '商圏の売上・客数',
  'retailmap_store_market_size': '商圏の市場規模',
  'retailmap_store_estimated_sales': '競合店の推定売上',
  'retailmap_store_competitor_detail': '競合店',
  'retailmap_store_customer_detail': '商圏の顧客',
  'retailmap_rival_company_list': '他社の一覧',
  'retailmap_rival_store_list': '他社の店舗',
  'retailmap_rival_trade_area_available': '他社店舗の商圏',
  'retailmap_rival_trade_area_census': '他社店舗の商圏人口',
  'retailmap_rival_market_size': '他社店舗の市場規模',
  'retailmap_rival_estimated_sales': '他社店舗の推定売上',
  'retailmap_rival_competitor_detail': '他社店舗の競合',
};

/// 写真のアップロード中に [_ChatEntry.runningTool] に入れる名前(ツール名とは重ならない)。
const _uploadingPhotos = '_uploading_photos';

/// 1 つの質問に付けられる写真の数(mdlink-mobile-app-agent と同じ)。
const _maxPhotos = 3;

String _toolStatus(String tool) => tool == _uploadingPhotos
    ? '写真を送信中…'
    : '「${_toolLabels[tool] ?? 'データ'}」を取得中…';

class _AiChatPageState extends State<AiChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatEntry> _entries = [];

  /// 次の質問に付ける写真(入力欄の上にサムネイルで出す)。
  final List<Uint8List> _pendingPhotos = [];
  bool _waiting = false;
  late final AiAssistant _assistant =
      widget.assistant ?? AiAssistantLocator.instance;
  late final VoiceInput _voice = widget.voiceInput ?? ContinuousVoiceInput();
  bool _listening = false;
  late final SpeechOutput _speech =
      widget.speechOutput ?? SpeechOutputLocator.instance;

  /// 読み上げ中の回答と、読み終えた割合(0.0〜1.0)。
  _ChatEntry? _speaking;
  double _speakProgress = 0;

  /// 回答が届き終わったら自動で読み上げるか。端末に保存する(既定はオン)。
  static const _autoSpeakKey = 'ai.autoSpeak';
  bool _autoSpeak = true;

  @override
  void initState() {
    super.initState();
    _loadAutoSpeak();
    _restoreConversation();
  }

  /// 前回の会話の ID。アプリを開き直しても、「新しい会話」を押すまで同じ会話を続ける。
  static const _lastConversationKey = 'ai.lastConversationId';

  /// 前回の会話を読み込む。
  Future<void> _restoreConversation() async {
    if (!_assistant.supportsHistory) return;
    String? id;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString(_lastConversationKey);
    } catch (_) {}
    if (id == null || !mounted || _entries.isNotEmpty || _waiting) return;
    try {
      final messages = await _assistant.loadMessages(id);
      if (mounted && _entries.isEmpty && !_waiting) {
        _showConversation(id, messages);
      }
    } catch (_) {
      // 消された会話などは読み込めないので、次の質問から新しい会話にする
      await _saveConversationId(null);
    }
  }

  Future<void> _saveConversationId(String? id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null) {
        await prefs.remove(_lastConversationKey);
      } else {
        await prefs.setString(_lastConversationKey, id);
      }
    } catch (_) {}
  }

  Future<void> _loadAutoSpeak() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_autoSpeakKey);
    if (mounted && value != null) setState(() => _autoSpeak = value);
  }

  Future<void> _toggleAutoSpeak() async {
    final value = !_autoSpeak;
    setState(() => _autoSpeak = value);
    // オフにしたら今の読み上げも止める
    if (!value) _stopSpeaking();
    _showSnack(value ? '回答を自動で読み上げます' : '自動読み上げをオフにしました');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSpeakKey, value);
  }

  /// 続けて質問するときの会話 ID。null なら次の質問で新しい会話になる。
  String? _conversationId;

  /// 入力欄の内容が音声入力によるものか(吹き出しの下に「音声入力」と出す)。
  bool _voiceUsed = false;

  /// 聞き取りを始める・終えるたびに +1。送信後に認識器から遅れて届く結果で、
  /// 空にした入力欄が埋め戻されないよう、今の回の結果だけを受け付ける。
  int _voiceSession = 0;

  @override
  void dispose() {
    if (_listening) _voice.stop();
    if (_speaking != null) {
      // 停止の通知で setState しないよう、先に読み上げ中の印を消す
      _speaking = null;
      _speech.stop();
    }
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 読み上げを止める(新しい質問・音声入力・会話の切り替え時にも呼ぶ)。
  void _stopSpeaking() {
    if (_speaking == null) return;
    _speech.stop();
    setState(() => _speaking = null);
  }

  Future<void> _toggleSpeak(_ChatEntry entry) async {
    if (_speaking == entry) {
      _stopSpeaking();
      return;
    }
    await _startSpeaking(entry);
  }

  Future<void> _startSpeaking(_ChatEntry entry) async {
    if (_speaking != null) _speech.stop();
    setState(() {
      _speaking = entry;
      _speakProgress = 0;
    });
    final started = await _speech.speak(
      entry.displayReply.text,
      onProgress: (p) {
        if (mounted && _speaking == entry) setState(() => _speakProgress = p);
      },
      onDone: () {
        if (mounted && _speaking == entry) setState(() => _speaking = null);
      },
    );
    if (!mounted || started) return;
    if (_speaking == entry) setState(() => _speaking = null);
    _showSnack('音声読み上げを利用できません。端末の音声合成(日本語)の設定を確認してください');
  }

  /// 入力欄の「+」:追加の入力手段を選ぶ(写真の撮影・選択、バーコードスキャン)。
  Future<void> _openAttachMenu() async {
    if (_waiting) return;
    final canAddPhoto = _pendingPhotos.length < _maxPhotos;
    final photoNote =
        canAddPhoto ? '売場や棚の写真について質問できます' : '写真は $_maxPhotos 枚までです';
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AttachOption(
                enabled: canAddPhoto,
                icon: Icons.photo_camera_outlined,
                title: '写真を撮る',
                subtitle: photoNote,
                onTap: () => Navigator.of(context).pop('camera'),
              ),
              _AttachOption(
                enabled: canAddPhoto,
                icon: Icons.photo_library_outlined,
                title: '写真を選ぶ',
                onTap: () => Navigator.of(context).pop('gallery'),
              ),
              _AttachOption(
                icon: Icons.qr_code_scanner,
                title: 'バーコードをスキャン',
                subtitle: '商品の JAN を入力欄に入れます',
                onTap: () => Navigator.of(context).pop('scan'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'scan':
        await _scanBarcode();
      case 'camera':
        await _pickPhoto(PhotoSource.camera);
      case 'gallery':
        await _pickPhoto(PhotoSource.gallery);
    }
  }

  Future<void> _pickPhoto(PhotoSource source) async {
    // カメラに移る前に聞き取りと読み上げを止める(バーコードスキャンと同じ)
    _voiceSession++;
    if (_listening) await _voice.stop();
    _stopSpeaking();
    Uint8List? bytes;
    try {
      bytes = await PhotoPickerLauncher.pick(source);
    } catch (_) {
      if (mounted) _showSnack('写真を取得できませんでした。カメラ・写真の権限を確認してください');
      return;
    }
    if (!mounted || bytes == null || bytes.isEmpty) return;
    if (_pendingPhotos.length >= _maxPhotos) return;
    final picked = bytes;
    setState(() => _pendingPhotos.add(picked));
  }

  Future<void> _scanBarcode() async {
    // 聞き取り中にカメラへ移ると、戻ったときに結果が混ざるので止めておく
    _voiceSession++;
    if (_listening) await _voice.stop();
    _stopSpeaking();
    if (!mounted) return;
    final code = await BarcodeScanLauncher.open(context);
    if (!mounted || code == null || code.isEmpty) return;
    _insertText(code);
  }

  /// カーソル位置(無ければ末尾)に文字を入れる。前に文字があれば半角スペースで区切る。
  void _insertText(String text) {
    final value = _controller.value;
    final current = value.text;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : current.length;
    final end = sel.isValid ? sel.end : current.length;
    final before = current.substring(0, start);
    final needsSpace = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before);
    final insert = '${needsSpace ? ' ' : ''}$text';
    final next = before + insert + current.substring(end);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _voice.stop();
      return;
    }
    // 読み上げの音声をマイクが拾わないように止める
    _stopSpeaking();
    // 認識結果は入力済みの文字の後ろにつなげる
    final prefix = _controller.text.trim();
    final session = ++_voiceSession;
    setState(() => _listening = true);
    final started = await _voice.start(
      onResult: (text, _) {
        if (!mounted || text.isEmpty || session != _voiceSession) return;
        final value = prefix.isEmpty ? text : '$prefix $text';
        _controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        _voiceUsed = true;
      },
      onDone: (error) {
        if (!mounted) return;
        setState(() => _listening = false);
        // 何も話さずに時間切れ(error_no_match / error_speech_timeout)はエラーにしない
        if (error != null &&
            error != 'error_no_match' &&
            error != 'error_speech_timeout') {
          _showSnack('音声を認識できませんでした（$error）');
        }
      },
    );
    if (!mounted) return;
    if (!started) {
      setState(() => _listening = false);
      _showSnack('音声入力を利用できません。マイクの権限と Google 音声サービスを確認してください');
    }
  }

  Future<void> _send(String raw) async {
    final question = raw.trim();
    // 写真だけの質問も送れる
    if ((question.isEmpty && _pendingPhotos.isEmpty) || _waiting) return;
    _stopSpeaking();
    // 先に今の聞き取りの回を無効にしてから止め、後から届く結果は捨てる
    _voiceSession++;
    if (_listening) await _voice.stop();
    final viaVoice = _voiceUsed;
    _voiceUsed = false;
    _controller.clear();
    // IME(Gboard など)で変換中に空にすると、次のフレームで変換中の文字が戻ることがあるので、もう一度空にする
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.text.trim() == question) _controller.clear();
    });
    final photos = List.of(_pendingPhotos);
    final answer = _ChatEntry.ai(DateTime.now());
    var failed = false;
    setState(() {
      _pendingPhotos.clear();
      _entries.add(_ChatEntry.user(
        question,
        DateTime.now(),
        viaVoice: viaVoice,
        photos: [for (final p in photos) _Photo.local(p)],
      ));
      _entries.add(answer);
      _waiting = true;
      if (photos.isNotEmpty) answer.runningTool = _uploadingPhotos;
    });
    _scrollToBottom();
    try {
      // 写真は先にアップロードし、質問では id だけを送る
      final imageIds = <String>[];
      for (final p in photos) {
        imageIds.add(await _assistant.uploadImage(p));
      }
      if (!mounted) return;
      if (photos.isNotEmpty) setState(() => answer.runningTool = null);
      await for (final event in _assistant.ask(
        question,
        conversationId: _conversationId,
        imageIds: imageIds,
      )) {
        if (!mounted) return;
        setState(() {
          switch (event) {
            case AiStarted(:final conversationId):
              if (_conversationId != conversationId) {
                _saveConversationId(conversationId);
              }
              _conversationId = conversationId;
            case AiTextDelta(:final text):
              answer.text.write(text);
            case AiChartReceived(:final chart):
              answer.charts.add(chart);
            case AiSuggestionsReceived(:final questions):
              answer.suggestions
                ..clear()
                ..addAll(questions);
            case AiToolProgress(:final name, :final status):
              answer.runningTool = status == 'running' ? name : null;
            case AiFinished(:final reply):
              answer.reply = reply;
            case AiFailed(:final message):
              failed = true;
              if (answer.text.isEmpty) answer.text.write(message);
          }
        });
        _scrollToBottom();
      }
    } catch (_) {
      failed = true;
      if (!mounted) return;
      setState(() {
        if (answer.text.isEmpty) answer.text.write('回答を取得できませんでした。');
      });
      _showSnack('回答を取得できませんでした。もう一度お試しください');
    } finally {
      if (mounted) {
        setState(() {
          answer
            ..streaming = false
            ..runningTool = null;
          // 何も届かずに終わった回答は表示しない
          if (answer.reply == null &&
              answer.text.isEmpty &&
              answer.charts.isEmpty) {
            _entries.remove(answer);
          }
          _waiting = false;
        });
      }
    }
    if (!mounted) return;
    _scrollToBottom();
    // 届き終わった回答を自動で読み上げる(エラーの回答は読まない)
    if (_autoSpeak && !failed && _entries.contains(answer)) {
      await _startSpeaking(answer);
    }
  }

  void _newConversation() {
    if (_waiting) return;
    _stopSpeaking();
    setState(() {
      _entries.clear();
      _pendingPhotos.clear();
      _conversationId = null;
    });
    _saveConversationId(null);
  }

  Future<void> _openHistory() async {
    if (_waiting) return;
    final selected = await showModalBottomSheet<AiConversationSummary>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _HistorySheet(
        assistant: _assistant,
        // 表示中の会話を消したら、画面も新しい会話に戻す
        onDeleted: (id) {
          if (id == _conversationId) _newConversation();
        },
      ),
    );
    if (selected == null || !mounted) return;
    _stopSpeaking();
    try {
      final messages = await _assistant.loadMessages(selected.id);
      if (!mounted) return;
      _showConversation(selected.id, messages);
      _saveConversationId(selected.id);
    } catch (_) {
      if (mounted) _showSnack('会話を読み込めませんでした');
    }
  }

  /// 保存済みの会話を画面に出す(履歴から選んだとき・前回の会話を開き直したとき)。
  void _showConversation(
      String conversationId, List<AiHistoryMessage> messages) {
    setState(() {
      _conversationId = conversationId;
      _entries
        ..clear()
        ..addAll(messages.map((m) => m.isUser
            ? _ChatEntry.user(
                m.text,
                m.createdAt,
                photos: [for (final id in m.imageIds) _Photo.remote(id)],
              )
            : _ChatEntry.ai(
                m.createdAt,
                text: m.text,
                streaming: false,
                charts: m.charts,
                suggestions: m.suggestions,
              )));
    });
    _scrollToBottom(animate: false);
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('ログアウトしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _stopSpeaking();
    _voiceSession++;
    if (_listening) await _voice.stop();
    await AuthManager.instance.signOut();
    await SessionStore().clear();
    // 次に別の人がログインしても前の会話を開かないよう、続きの会話 ID も消す
    await _saveConversationId(null);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  /// 一番下へ移る。リストは見えている分だけ組み立てるので、最初は最大位置が小さく見積もられる。
  /// 届いていなければ次のフレームでもう一度移る(最大 [retries] 回)。
  void _jumpToBottom(int retries) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    position.jumpTo(position.maxScrollExtent);
    if (retries <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final p = _scrollController.position;
      if (p.pixels < p.maxScrollExtent - 1) _jumpToBottom(retries - 1);
    });
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (!animate) {
        _jumpToBottom(3);
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _notReady(String feature) => _showSnack('$featureは準備中です');

  Widget _buildAnswer(_ChatEntry entry) {
    final tool = entry.runningTool;
    if (entry.streaming &&
        entry.text.isEmpty &&
        entry.reply == null &&
        entry.charts.isEmpty) {
      return _TypingIndicator(
        label: tool == null ? '回答を作成中…' : _toolStatus(tool),
      );
    }
    // 質問候補は最新の回答にだけ出す(古い回答にも並ぶと紛らわしい)
    final latest = _entries.lastWhere((e) => !e.isUser, orElse: () => entry);
    final reply = entry.reply ??
        AiReply(
          text: entry.text.toString(),
          answeredAt: entry.at,
          followUps: identical(latest, entry) ? entry.suggestions : const [],
        );
    return _AiAnswer(
      reply: reply,
      charts: entry.charts,
      streaming: entry.streaming,
      status: tool == null ? null : _toolStatus(tool),
      speaking: _speaking == entry,
      speakProgress: _speakProgress,
      onSpeak: () => _toggleSpeak(entry),
      onAction: _notReady,
      onFollowUp: _send,
    );
  }

  @override
  Widget build(BuildContext context) {
    final empty = _entries.isEmpty;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: AuroraBackground(
        intensity: empty ? 1 : 0.55,
        child: SafeArea(
          child: Column(
            children: [
              _Header(
                thinking: _waiting,
                autoSpeak: _autoSpeak,
                supportsHistory: _assistant.supportsHistory,
                canStartNew: !_waiting && !empty,
                onToggleAutoSpeak: _toggleAutoSpeak,
                onHistory: _waiting ? null : _openHistory,
                onNewConversation: _newConversation,
                onLogout: _confirmLogout,
              ),
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.xl,
                  ),
                  children: [
                    if (empty)
                      _Welcome(onSelected: _send)
                    else ...[
                      Center(child: _DateBadge(date: DateTime.now())),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                    for (final entry in _entries) ...[
                      if (entry.isUser)
                        _UserBubble(
                          text: entry.question!,
                          at: entry.at,
                          viaVoice: entry.viaVoice,
                          photos: entry.photos,
                          loadImage: _assistant.loadImage,
                        )
                      else
                        _buildAnswer(entry),
                      const SizedBox(height: 20),
                    ],
                  ],
                ),
              ),
              if (_pendingPhotos.isNotEmpty)
                _PendingPhotos(
                  photos: _pendingPhotos,
                  enabled: !_waiting,
                  onRemove: (i) => setState(() => _pendingPhotos.removeAt(i)),
                ),
              _InputBar(
                controller: _controller,
                enabled: !_waiting,
                listening: _listening,
                onSend: () => _send(_controller.text),
                onMic: _toggleVoice,
                onAttach: _openAttachMenu,
                // 入力欄を手で空にしたら、音声入力扱いをやめる
                onChanged: (text) {
                  if (text.isEmpty) _voiceUsed = false;
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 上部
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.thinking,
    required this.autoSpeak,
    required this.supportsHistory,
    required this.canStartNew,
    required this.onToggleAutoSpeak,
    required this.onHistory,
    required this.onNewConversation,
    required this.onLogout,
  });

  final bool thinking;
  final bool autoSpeak;
  final bool supportsHistory;
  final bool canStartNew;
  final VoidCallback onToggleAutoSpeak;
  final VoidCallback? onHistory;
  final VoidCallback onNewConversation;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final user = AuthManager.instance.session?.user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          AiOrb(size: 40, active: thinking),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const GradientText(
                  'AI PACER',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 3),
                StatusPill(
                  label: thinking ? 'THINKING' : 'ONLINE',
                  color: thinking ? AppColors.violet : AppColors.success,
                ),
              ],
            ),
          ),
          GlassIconButton(
            tooltip: autoSpeak ? '自動読み上げ:オン' : '自動読み上げ:オフ',
            onPressed: onToggleAutoSpeak,
            icon: autoSpeak
                ? Icons.volume_up_outlined
                : Icons.volume_off_outlined,
            color: autoSpeak ? AppColors.cyan : AppColors.secondaryText,
          ),
          if (supportsHistory) ...[
            const SizedBox(width: 6),
            GlassIconButton(
              tooltip: '会話履歴',
              onPressed: onHistory,
              icon: Icons.history_rounded,
            ),
            const SizedBox(width: 6),
            GlassIconButton(
              tooltip: '新しい会話',
              onPressed: canStartNew ? onNewConversation : null,
              icon: Icons.add_comment_outlined,
            ),
          ],
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: 'アカウント',
            offset: const Offset(0, 48),
            onSelected: (value) {
              if (value == 'logout') onLogout();
            },
            itemBuilder: (context) => [
              if (user != null)
                PopupMenuItem<String>(
                  enabled: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.displayName,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        user.email,
                        style: const TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              const PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 18, color: AppColors.error),
                    SizedBox(width: 10),
                    Text('ログアウト'),
                  ],
                ),
              ),
            ],
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: kNeonGradient,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.violet.withValues(alpha: 0.4),
                    blurRadius: 12,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(1.5),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.bg1,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initial(user),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _initial(AuthUser? user) {
    final name = user?.displayName.trim() ?? '';
    return name.isEmpty ? '?' : name.characters.first.toUpperCase();
  }
}

// ---------------------------------------------------------------------------
// 最初の画面
// ---------------------------------------------------------------------------

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const Center(child: AiOrb(size: 150)),
        const SizedBox(height: 10),
        const GradientText(
          'こんにちは',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          '何を分析しますか？',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.text,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '店舗を含めて質問してください(例:67番店舗)',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.secondaryText, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in _capabilities)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: AppColors.cyan.withValues(alpha: 0.3)),
                  color: AppColors.cyan.withValues(alpha: 0.06),
                ),
                child: Text(
                  '# $c',
                  style: monoStyle(
                    size: 10.5,
                    color: AppColors.cyan,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text('SUGGESTED PROMPTS', style: monoStyle(size: 10, letterSpacing: 2)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.35,
          children: [
            for (final s in _initialSuggestions)
              _PromptCard(
                icon: s.icon,
                title: s.title,
                question: s.question,
                onTap: () => onSelected(s.question),
              ),
          ],
        ),
      ],
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.icon,
    required this.title,
    required this.question,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String question;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: question,
      excludeSemantics: true,
      child: GlassPanel(
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(colors: [
                            AppColors.cyan.withValues(alpha: 0.25),
                            AppColors.violet.withValues(alpha: 0.25),
                          ]),
                        ),
                        child: Icon(icon, size: 16, color: AppColors.cyan),
                      ),
                      const Spacer(),
                      const Icon(Icons.north_east_rounded,
                          size: 14, color: AppColors.mutedText),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    question,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.secondaryText,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 会話履歴
// ---------------------------------------------------------------------------

/// 会話履歴の一覧。選んだ会話を返す。ゴミ箱アイコンで削除できる。
class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.assistant, required this.onDeleted});

  final AiAssistant assistant;
  final ValueChanged<String> onDeleted;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late Future<List<AiConversationSummary>> _future =
      widget.assistant.listConversations();

  Future<void> _delete(AiConversationSummary c) async {
    try {
      await widget.assistant.deleteConversation(c.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('削除できませんでした')),
      );
      return;
    }
    widget.onDeleted(c.id);
    if (!mounted) return;
    setState(() {
      _future = widget.assistant.listConversations();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.65,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                const Text(
                  '会話履歴',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
                Text('HISTORY', style: monoStyle(size: 10)),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<AiConversationSummary>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: PulseDots());
                }
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('履歴を読み込めませんでした',
                        style: TextStyle(color: AppColors.secondaryText)),
                  );
                }
                final items = snapshot.data ?? const [];
                if (items.isEmpty) {
                  return const Center(
                    child: Text('まだ会話がありません',
                        style: TextStyle(color: AppColors.secondaryText)),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final c = items[i];
                    final store =
                        c.storeCode.isEmpty ? '' : '  ·  店舗 ${c.storeCode}';
                    return Material(
                      color: AppColors.glass,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        side: const BorderSide(color: AppColors.border),
                      ),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        leading: const Icon(Icons.chat_bubble_outline_rounded,
                            color: AppColors.cyan, size: 20),
                        title: Text(
                          c.title.isEmpty ? '(無題)' : c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          '${c.updatedAt.month}/${c.updatedAt.day} '
                          '${_hhmm(c.updatedAt)}$store',
                          style: monoStyle(size: 10.5, letterSpacing: 0.5),
                        ),
                        onTap: () => Navigator.of(context).pop(c),
                        trailing: IconButton(
                          tooltip: '削除',
                          icon: const Icon(Icons.delete_outline,
                              color: AppColors.secondaryText),
                          onPressed: () => _delete(c),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// メッセージ
// ---------------------------------------------------------------------------

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _yen(int amount) {
  final digits = amount.toString();
  final buf = StringBuffer('¥');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.date});

  final DateTime date;

  static const _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 24, height: 1, color: AppColors.border),
        const SizedBox(width: 8),
        Text(
          '本日 ${date.month}月${date.day}日 (${_weekdays[date.weekday - 1]})',
          style: monoStyle(size: 10, letterSpacing: 1),
        ),
        const SizedBox(width: 8),
        Container(width: 24, height: 1, color: AppColors.border),
      ],
    );
  }
}

/// 回答の見出しに付ける小さな光る点(アニメーションしない)。
class _MiniOrb extends StatelessWidget {
  const _MiniOrb();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.3, -0.35),
          colors: [Colors.white, AppColors.cyan, AppColors.violet],
          stops: [0, 0.3, 1],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.violet.withValues(alpha: 0.6),
            blurRadius: 10,
          ),
        ],
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.text,
    required this.at,
    this.viaVoice = false,
    this.photos = const [],
    required this.loadImage,
  });

  final String text;
  final DateTime at;
  final bool viaVoice;
  final List<_Photo> photos;
  final Future<Uint8List> Function(String id) loadImage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (photos.isNotEmpty) ...[
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in photos)
                  _PhotoThumb(photo: p, loadImage: loadImage, size: 120),
              ],
            ),
            if (text.isNotEmpty) const SizedBox(height: 6),
          ],
          if (text.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: kUserGradient,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.xl),
                  topRight: Radius.circular(AppRadius.xl),
                  bottomLeft: Radius.circular(AppRadius.xl),
                  bottomRight: Radius.circular(4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.violet.withValues(alpha: 0.35),
                    blurRadius: 18,
                    spreadRadius: -6,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  height: 1.55,
                ),
              ),
            ),
          const SizedBox(height: 5),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (viaVoice) ...[
                const Icon(Icons.graphic_eq,
                    size: 13, color: AppColors.secondaryText),
                const SizedBox(width: 3),
              ],
              Text(
                '${viaVoice ? '音声入力' : '送信'} ${_hhmm(at)}',
                style: monoStyle(size: 10, letterSpacing: 0.5),
              ),
              const SizedBox(width: 3),
              const Icon(Icons.done_all, size: 13, color: AppColors.cyan),
            ],
          ),
        ],
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator({this.label = '回答を作成中…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const AiOrb(size: 34, active: true),
        const SizedBox(width: 8),
        GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          radius: 999,
          borderColor: AppColors.violet.withValues(alpha: 0.35),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PulseDots(),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AiAnswer extends StatelessWidget {
  const _AiAnswer({
    required this.reply,
    required this.onAction,
    required this.onFollowUp,
    this.charts = const [],
    this.streaming = false,
    this.status,
    this.speaking = false,
    this.speakProgress = 0,
    this.onSpeak,
  });

  final AiReply reply;

  /// 本文の下に描くグラフ。
  final List<AiChart> charts;

  /// 読み上げ中か、読み終えた割合、再生ボタンを押したとき。
  final bool speaking;
  final double speakProgress;
  final VoidCallback? onSpeak;

  /// 回答の受信中。読み上げバーと続きの質問候補はまだ出さない。
  final bool streaming;

  /// データ取得中などの状態表示(「店舗の売上」を取得中… など)。
  final String? status;
  final ValueChanged<String> onAction;
  final ValueChanged<String> onFollowUp;

  @override
  Widget build(BuildContext context) {
    final aggregatedAt = reply.aggregatedAt;
    final insight = reply.insight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _MiniOrb(),
            const SizedBox(width: 8),
            const Text(
              'PACER AI',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(width: 8),
            Text(_hhmm(reply.answeredAt), style: monoStyle(size: 10)),
            if (reply.tag != null) ...[
              const SizedBox(width: 8),
              Flexible(child: _Tag(text: reply.tag!)),
            ],
            if (reply.isDemo) ...[
              const SizedBox(width: 4),
              const _Tag(text: 'デモデータ', color: AppColors.warning),
            ],
          ],
        ),
        const SizedBox(height: 10),
        GlassPanel(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          borderColor: AppColors.cyan.withValues(alpha: 0.16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (aggregatedAt != null) ...[
                Text('集計 ${_hhmm(aggregatedAt)} 時点',
                    style: monoStyle(size: 10)),
                const SizedBox(height: 6),
              ],
              _AnswerText(text: reply.text, streaming: streaming),
              for (final chart in charts) ...[
                const _SectionDivider(),
                AiChartView(chart: chart),
              ],
              if (status != null) ...[
                const SizedBox(height: 12),
                _ToolStatus(label: status!),
              ],
              if (reply.metrics.isNotEmpty) ...[
                const _SectionDivider(),
                _MetricGrid(metrics: reply.metrics),
              ],
              if (reply.categories.isNotEmpty) ...[
                const _SectionDivider(),
                _CategoryBreakdown(categories: reply.categories),
              ],
              if (insight != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _InsightCard(insight: insight, onAction: onAction),
              ],
              if (!streaming) ...[
                const SizedBox(height: AppSpacing.lg),
                _NarrationBar(
                  playing: speaking,
                  progress: speaking ? speakProgress : 0,
                  onPlay: onSpeak ?? () => onAction('音声読み上げ'),
                ),
              ],
            ],
          ),
        ),
        if (!streaming && reply.followUps.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _SuggestionChips(
            suggestions: reply.followUps,
            onSelected: onFollowUp,
          ),
        ],
      ],
    );
  }
}

/// 回答の本文。受信中は末尾に光るカーソルを出す。
class _AnswerText extends StatelessWidget {
  const _AnswerText({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: AppColors.text, fontSize: 14.5, height: 1.7);
    if (!streaming) return Text(text, style: style);
    return Text.rich(
      TextSpan(
        text: text,
        style: style,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.only(left: 3),
              width: 8,
              height: 16,
              decoration: BoxDecoration(
                gradient: kNeonGradient,
                borderRadius: BorderRadius.circular(2),
                boxShadow: const [
                  BoxShadow(color: AppColors.cyan, blurRadius: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// データ取得中の表示(回答の途中で別のデータを取りに行くとき)。
class _ToolStatus extends StatelessWidget {
  const _ToolStatus({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.violet.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.violet.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('TOOL ›', style: monoStyle(size: 10, color: AppColors.violet)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const PulseDots(color: AppColors.violet, size: 4),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.color = AppColors.cyan});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Divider(height: 1),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<AiMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _MetricTile(metric: metrics[i])),
          ],
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final AiMetric metric;

  @override
  Widget build(BuildContext context) {
    final trendColor = switch (metric.trend) {
      AiTrend.up => AppColors.success,
      AiTrend.down => AppColors.error,
      AiTrend.flat => AppColors.secondaryText,
    };
    final trendIcon = switch (metric.trend) {
      AiTrend.up => Icons.arrow_upward,
      AiTrend.down => Icons.arrow_downward,
      AiTrend.flat => Icons.trending_flat,
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.glass,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            metric.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.secondaryText,
              fontSize: 10.5,
            ),
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              text: metric.value,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
              children: [
                if (metric.unit != null)
                  TextSpan(
                    text: metric.unit,
                    style: const TextStyle(
                      color: AppColors.secondaryText,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(trendIcon, size: 12, color: trendColor),
              const SizedBox(width: 2),
              Text(
                metric.delta,
                style: TextStyle(
                  color: trendColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            metric.note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:
                  metric.highlightNote ? trendColor : AppColors.secondaryText,
              fontSize: 9,
              fontWeight:
                  metric.highlightNote ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryBreakdown extends StatelessWidget {
  const _CategoryBreakdown({required this.categories});

  final List<AiCategorySales> categories;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.category_outlined,
                size: 15, color: AppColors.cyan),
            const SizedBox(width: 6),
            const Text(
              'カテゴリ別売上推移',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Text('目標進捗率', style: monoStyle(size: 10, letterSpacing: 0.5)),
          ],
        ),
        for (final c in categories) ...[
          const SizedBox(height: 12),
          _CategoryRow(category: c),
        ],
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category});

  final AiCategorySales category;

  @override
  Widget build(BuildContext context) {
    // 100% 以上は緑、未達は黄。棒は 100% で満タン
    final onTrack = category.progress >= 1.0;
    final accent = onTrack ? AppColors.success : AppColors.warning;
    final percent = (category.progress * 100).round();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                category.name,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              _yen(category.amount),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Container(
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.glassStrong,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Container(
                height: 5,
                width:
                    constraints.maxWidth * category.progress.clamp(0.0, 1.0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: onTrack
                      ? kNeonGradient
                      : const LinearGradient(colors: [
                          AppColors.warning,
                          Color(0xFFF97316),
                        ]),
                  boxShadow: [
                    BoxShadow(
                      color: (onTrack ? AppColors.cyan : AppColors.warning)
                          .withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.insight, required this.onAction});

  final AiInsight insight;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final actionLabel = insight.actionLabel;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.warning.withValues(alpha: 0.10),
            AppColors.violet.withValues(alpha: 0.06),
          ],
        ),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome,
                  size: 16, color: AppColors.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  insight.title,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _Tag(text: insight.tag, color: AppColors.warning),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            insight.body,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 12.5,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (actionLabel != null)
                Expanded(
                  child: NeonButton(
                    label: actionLabel,
                    icon: Icons.add_task,
                    height: 38,
                    onPressed: () => onAction(actionLabel),
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => onAction('詳細グラフ'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.text,
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  side: const BorderSide(color: AppColors.borderStrong),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text('詳細グラフ', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NarrationBar extends StatelessWidget {
  const _NarrationBar({
    required this.onPlay,
    this.playing = false,
    this.progress = 0,
  });

  final VoidCallback onPlay;
  final bool playing;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
      decoration: BoxDecoration(
        color: AppColors.bg0.withValues(alpha: 0.35),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Tooltip(
            message: playing ? '読み上げを停止' : '読み上げ',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: Ink(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: kNeonGradient,
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onPlay,
                  child: SizedBox.square(
                    dimension: 32,
                    child: Icon(
                      playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      playing ? '読み上げ中…' : '音声読み上げ',
                      style: TextStyle(
                        color:
                            playing ? AppColors.cyan : AppColors.secondaryText,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: WaveBars(playing: playing, height: 16, bars: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      Container(
                        height: 2,
                        color: AppColors.glassStrong,
                      ),
                      Container(
                        height: 2,
                        width: constraints.maxWidth * progress.clamp(0.0, 1.0),
                        decoration:
                            const BoxDecoration(gradient: kNeonGradient),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「続けて聞く」質問候補。
class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({required this.suggestions, required this.onSelected});

  final List<String> suggestions;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in suggestions)
          Material(
            color: AppColors.glass,
            shape: StadiumBorder(
              side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.3)),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onSelected(s),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.subdirectory_arrow_right_rounded,
                        size: 14, color: AppColors.cyan),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        s,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 入力欄
// ---------------------------------------------------------------------------

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.listening,
    required this.onSend,
    required this.onMic,
    required this.onAttach,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool listening;
  final VoidCallback onSend;
  final VoidCallback onMic;

  /// 「+」:写真・バーコードスキャンなどの追加の入力手段。
  final VoidCallback onAttach;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    const none = OutlineInputBorder(borderSide: BorderSide.none);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
        radius: 28,
        color: AppColors.slate900.withValues(alpha: 0.75),
        borderColor: listening
            ? AppColors.error.withValues(alpha: 0.6)
            : AppColors.cyan.withValues(alpha: 0.28),
        glow: listening ? AppColors.error : AppColors.cyan,
        child: Row(
          // 複数行になったとき、ボタンは入力欄の下端にそろえる
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'その他の入力',
              onPressed: enabled ? onAttach : null,
              icon: const Icon(Icons.add_rounded),
              color: AppColors.cyan,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                // 複数行の入力。改行キーは改行で、送信は「送信」ボタンだけ
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 1,
                maxLines: 6,
                onChanged: onChanged,
                cursorColor: AppColors.cyan,
                style: const TextStyle(color: AppColors.text, fontSize: 14.5),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  // 複数行の入力欄でもヒントは 1 行に収める(折り返すと空欄でも 2 行の高さになる)
                  hintText: listening ? '聞き取り中…(🎤 で終了)' : 'PACER AI に質問…',
                  hintMaxLines: 1,
                  hintStyle: TextStyle(
                    color: listening ? AppColors.error : AppColors.mutedText,
                    fontSize: 14,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
                  border: none,
                  enabledBorder: none,
                  focusedBorder: none,
                ),
              ),
            ),
            // 聞き取り中は赤い mic(もう一度押すと停止)
            IconButton(
              tooltip: listening ? '音声入力を停止' : '音声入力',
              onPressed: onMic,
              icon: listening
                  ? const Icon(Icons.mic, color: AppColors.error)
                  : const Icon(Icons.mic_none_rounded,
                      color: AppColors.secondaryText),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Tooltip(
                message: '送信',
                child: Semantics(
                  button: true,
                  label: '送信',
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: enabled ? 1 : 0.4,
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      child: Ink(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: kNeonGradient,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.cyan.withValues(alpha: 0.5),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: enabled ? onSend : null,
                          child: const SizedBox.square(
                            dimension: 42,
                            child: Icon(Icons.arrow_upward_rounded,
                                color: Colors.white, size: 22),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「+」メニューの 1 行。
class _AttachOption extends StatelessWidget {
  const _AttachOption({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: AppColors.cyan.withValues(alpha: enabled ? 0.12 : 0.04),
        ),
        child: Icon(icon,
            color: enabled ? AppColors.cyan : AppColors.mutedText, size: 20),
      ),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              style: const TextStyle(
                  color: AppColors.secondaryText, fontSize: 12)),
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------------------
// 写真
// ---------------------------------------------------------------------------

/// 送信済みの写真のサムネイル。タップで全画面表示。履歴の写真は id から読み込む。
class _PhotoThumb extends StatefulWidget {
  const _PhotoThumb({
    required this.photo,
    required this.loadImage,
    required this.size,
  });

  final _Photo photo;
  final Future<Uint8List> Function(String id) loadImage;
  final double size;

  @override
  State<_PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<_PhotoThumb> {
  late final Future<Uint8List> _bytes = widget.photo.bytes != null
      ? Future.value(widget.photo.bytes!)
      : widget.loadImage(widget.photo.id!);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderStrong),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox.square(
          dimension: widget.size,
          child: FutureBuilder<Uint8List>(
            future: _bytes,
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes == null || bytes.isEmpty) {
                return ColoredBox(
                  color: AppColors.glass,
                  child: Center(
                    child: snap.hasError || bytes != null
                        ? const Icon(Icons.broken_image_outlined,
                            color: AppColors.secondaryText)
                        : const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  ),
                );
              }
              return GestureDetector(
                onTap: () => _showPhoto(context, bytes),
                child: Image.memory(bytes, fit: BoxFit.cover),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 写真を全画面で表示する(ピンチで拡大)。
void _showPhoto(BuildContext context, Uint8List bytes) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (context) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.memory(bytes),
        ),
      ),
    ),
  ));
}

/// 次の質問に付ける写真(入力欄の上)。× で外せる。
class _PendingPhotos extends StatelessWidget {
  const _PendingPhotos({
    required this.photos,
    required this.enabled,
    required this.onRemove,
  });

  final List<Uint8List> photos;
  final bool enabled;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Wrap(
        spacing: 14,
        children: [
          for (var i = 0; i < photos.length; i++)
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                        color: AppColors.cyan.withValues(alpha: 0.5)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: GestureDetector(
                      onTap: () => _showPhoto(context, photos[i]),
                      child: Image.memory(
                        photos[i],
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -14,
                  right: -14,
                  child: IconButton(
                    tooltip: '写真を外す',
                    visualDensity: VisualDensity.compact,
                    onPressed: enabled ? () => onRemove(i) : null,
                    icon: const Icon(Icons.cancel,
                        size: 20, color: AppColors.text),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
