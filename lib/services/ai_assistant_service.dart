import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_chat.dart';
import 'api_client.dart';
import 'http_client_factory.dart'
    if (dart.library.io) 'http_client_factory_io.dart' as http_factory;

/// AI アソシエイトの回答元。
///
/// - [BackendAiAssistant]:mdlink-mobile-app-agent(Cloud Run)に問い合わせる。回答は SSE で少しずつ届く
/// - [MockAiAssistant]:`design/8.AIChat` のデモデータを返す。`AI_AGENT_BASE_URL` 未設定時に使う
///
/// 画面は [AiEvent] のストリームだけを見るので、回答元を替えても画面は変えない。
abstract class AiAssistant {
  /// 会話履歴(一覧・再表示・削除)に対応しているか。
  bool get supportsHistory;

  /// 質問を送る。[conversationId] が null なら新しい会話を始める。
  /// [imageIds] は先に [uploadImage] した写真(最大 3 枚)。写真があれば [question] は空でもよい。
  Stream<AiEvent> ask(
    String question, {
    String? conversationId,
    String? companyCode,
    String? storeCode,
    String? storeName,
    List<String> imageIds = const [],
  });

  /// 質問に付ける写真をアップロードし、id を返す。
  Future<String> uploadImage(Uint8List bytes);

  /// 履歴の写真を取得する。
  Future<Uint8List> loadImage(String id);

  Future<List<AiConversationSummary>> listConversations();

  Future<List<AiHistoryMessage>> loadMessages(String conversationId);

  Future<void> deleteConversation(String conversationId);
}

/// 本番の mdlink-mobile-app-agent(Cloud Run)。
const _defaultAgentBaseUrl =
    'https://mdlink-mobile-app-agent-cjy6246wiq-an.a.run.app/api/v1/ai';

/// 画面で使う回答元を決める。既定は本番の agent。
/// `--dart-define=AI_AGENT_BASE_URL=https://.../api/v1/ai` で接続先を変えられ、
/// `AI_AGENT_BASE_URL=mock` ならデモデータ([MockAiAssistant])を返す。
class AiAssistantLocator {
  static const String agentBaseUrl = String.fromEnvironment(
    'AI_AGENT_BASE_URL',
    defaultValue: _defaultAgentBaseUrl,
  );

  static AiAssistant? _instance;

  static AiAssistant get instance =>
      _instance ??= agentBaseUrl.isEmpty || agentBaseUrl == 'mock'
          ? const MockAiAssistant()
          : BackendAiAssistant(baseUrl: agentBaseUrl);

  static void set(AiAssistant assistant) => _instance = assistant;

  static void reset() => _instance = null;
}

/// mdlink-mobile-app-agent の API を呼ぶ実装。
///
/// 認証は [ApiClient.authDelegate](WorkOS の access token)を共用する。
/// 401 のときは 1 回だけ token を更新して再送し、それでも駄目ならセッション切れとして扱う。
class BackendAiAssistant implements AiAssistant {
  BackendAiAssistant({required String baseUrl, http.Client? client})
      : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _client = client ?? http_factory.createHttpClient();

  final String _baseUrl;
  final http.Client _client;

  @override
  bool get supportsHistory => true;

  @override
  Stream<AiEvent> ask(
    String question, {
    String? conversationId,
    String? companyCode,
    String? storeCode,
    String? storeName,
    List<String> imageIds = const [],
  }) async* {
    final body = jsonEncode({
      'message': question,
      if (conversationId != null) 'conversationId': conversationId,
      if (companyCode != null) 'companyCode': companyCode,
      if (storeCode != null) 'storeCode': storeCode,
      if (storeName != null) 'storeName': storeName,
      if (imageIds.isNotEmpty) 'imageIds': imageIds,
    });
    final response = await _sendWithRefresh(() => http.Request(
          'POST',
          Uri.parse('$_baseUrl/chat'),
        )
          ..headers['Accept'] = 'text/event-stream'
          ..headers['Content-Type'] = 'application/json'
          ..body = body);

    if (response.statusCode != 200) {
      final text = await response.stream.bytesToString();
      throw ApiException(
        statusCode: response.statusCode,
        message: 'POST /chat failed: $text',
      );
    }

    // SSE:`data: {...}` の行を 1 イベントとして読む(Web 版は全文受信後にまとめて届く)
    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      final event =
          AiEvent.fromJson(jsonDecode(payload) as Map<String, dynamic>);
      if (event != null) yield event;
    }
  }

  @override
  Future<String> uploadImage(Uint8List bytes) async {
    final response = await _sendWithRefresh(() => http.Request(
          'POST',
          Uri.parse('$_baseUrl/images'),
        )
          // 種類はサーバーが先頭のバイト列で判定する
          ..headers['Content-Type'] = 'application/octet-stream'
          ..headers['Accept'] = 'application/json'
          ..bodyBytes = bytes);
    final text = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        statusCode: response.statusCode,
        message: 'POST /images failed: $text',
      );
    }
    final data = (jsonDecode(text) as Map<String, dynamic>)['data']
        as Map<String, dynamic>;
    final id = data['id'] as String;
    _images[id] = bytes;
    return id;
  }

  /// 取得済みの写真。写真は後から変わらないので、アプリを閉じるまで使い回す。
  final Map<String, Uint8List> _images = {};

  @override
  Future<Uint8List> loadImage(String id) async {
    final cached = _images[id];
    if (cached != null) return cached;
    final response = await _sendWithRefresh(
      () => http.Request('GET', Uri.parse('$_baseUrl/images/$id')),
    );
    final bytes = await response.stream.toBytes();
    if (response.statusCode != 200) {
      throw ApiException(
        statusCode: response.statusCode,
        message: 'GET /images failed',
      );
    }
    return _images[id] = bytes;
  }

  @override
  Future<List<AiConversationSummary>> listConversations() async {
    final data = await _getJson('/conversations?limit=50') as List<dynamic>;
    return data
        .map((e) => AiConversationSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<AiHistoryMessage>> loadMessages(String conversationId) async {
    final data = await _getJson('/conversations/$conversationId/messages')
        as Map<String, dynamic>;
    return (data['messages'] as List<dynamic>)
        .map((e) => AiHistoryMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final response = await _sendWithRefresh(() => http.Request(
          'DELETE',
          Uri.parse('$_baseUrl/conversations/$conversationId'),
        ));
    final text = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        statusCode: response.statusCode,
        message: 'DELETE /conversations failed: $text',
      );
    }
  }

  Future<dynamic> _getJson(String path) async {
    final response = await _sendWithRefresh(
      () => http.Request('GET', Uri.parse('$_baseUrl$path'))
        ..headers['Accept'] = 'application/json',
    );
    final text = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        statusCode: response.statusCode,
        message: 'GET $path failed: $text',
      );
    }
    // 共通形式 {"code":0,"message":"success","data":...}
    return (jsonDecode(text) as Map<String, dynamic>)['data'];
  }

  /// リクエストを送る。401 なら token を更新して 1 回だけ作り直して送る。
  Future<http.StreamedResponse> _sendWithRefresh(
    http.Request Function() build,
  ) async {
    final delegate = ApiClient.authDelegate;
    for (var attempt = 0;; attempt++) {
      final request = build();
      final token = delegate?.accessToken;
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      final response = await _client.send(request);
      if (response.statusCode != 401 || delegate == null) return response;
      await response.stream.drain<void>();
      if (attempt == 0 && await delegate.refreshAccessToken()) continue;
      delegate.onUnauthorized();
      throw ApiException(statusCode: 401, message: 'unauthorized');
    }
  }
}

/// デモ用:何を聞いても `design/8.AIChat` の売上サマリを返す。履歴は持たない。
class MockAiAssistant implements AiAssistant {
  const MockAiAssistant({this.latency = const Duration(milliseconds: 600)});

  final Duration latency;

  @override
  bool get supportsHistory => false;

  @override
  Stream<AiEvent> ask(
    String question, {
    String? conversationId,
    String? companyCode,
    String? storeCode,
    String? storeName,
    List<String> imageIds = const [],
  }) async* {
    await Future<void>.delayed(latency);
    yield AiFinished(reply: _demoReply(storeName));
  }

  @override
  Future<String> uploadImage(Uint8List bytes) async => 'demo';

  @override
  Future<Uint8List> loadImage(String id) async => Uint8List(0);

  @override
  Future<List<AiConversationSummary>> listConversations() async => const [];

  @override
  Future<List<AiHistoryMessage>> loadMessages(String conversationId) async =>
      const [];

  @override
  Future<void> deleteConversation(String conversationId) async {}

  AiReply _demoReply(String? storeName) {
    final now = DateTime.now();
    final store = (storeName == null || storeName.isEmpty) ? '担当店舗' : storeName;
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return AiReply(
      isDemo: true,
      answeredAt: now,
      aggregatedAt: now,
      tag: 'リアルタイム売上分析',
      text: '$storeの本日（${now.month}月${now.day}日 $hh:$mm時点）の売上サマリをご報告します。'
          '目標達成ペースで順調に推移しています。',
      metrics: const [
        AiMetric(
          label: '本日累計売上',
          value: '¥4,820,000',
          delta: '106.4%',
          note: '予算比 好調',
          highlightNote: true,
        ),
        AiMetric(
          label: '来客数',
          value: '2,140',
          unit: '人',
          delta: '+8.2%',
          note: '前週同曜比',
        ),
        AiMetric(
          label: '客単価',
          value: '¥2,252',
          delta: '+3.1%',
          note: '前週同曜比',
        ),
      ],
      categories: const [
        AiCategorySales(name: '食品・飲料', amount: 2450000, progress: 1.10),
        AiCategorySales(name: '生鮮・惣菜', amount: 1380000, progress: 1.04),
        AiCategorySales(name: '日用品', amount: 990000, progress: 0.98),
      ],
      insight: const AiInsight(
        title: 'AI示唆・注目インサイト',
        tag: '要確認',
        body: '「金鶴麦酒 プレミアムエール」が夕方ピーク前に在庫逼迫の兆候があります。補充タスクを推奨します。',
        actionLabel: '補充指示を作成',
      ),
      followUps: const ['時間帯別の客数推移は？', 'ビール売場の欠品リスク'],
    );
  }
}
