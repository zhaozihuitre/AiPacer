import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_pacer/main.dart';
import 'package:ai_pacer/models/ai_chat.dart';
import 'package:ai_pacer/pages/ai_chat_page.dart';
import 'package:ai_pacer/pages/barcode_scan_page.dart';
import 'package:ai_pacer/services/ai_assistant_service.dart';
import 'package:ai_pacer/services/api_client.dart';
import 'package:ai_pacer/services/auth_service.dart';
import 'package:ai_pacer/services/photo_picker.dart';
import 'package:ai_pacer/services/speech_output_service.dart';
import 'package:ai_pacer/services/voice_input_service.dart';
import 'package:ai_pacer/widgets/ai_chart_view.dart';
import 'package:ai_pacer/widgets/tech_ui.dart';

/// モックが受けたすべてのリクエスト(Authorization ヘッダーの確認などに使う)。
final List<http.Request> _requests = [];

/// /auth/config が返す enabled。
bool _authEnabled = true;

/// この Authorization の業務リクエストには 401 を返す(access token の期限切れを再現)。
final Set<String> _expiredTokens = {};

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _sessionJson(String access, String refresh) => {
      'accessToken': access,
      'refreshToken': refresh,
      'user': {
        'id': 'user_01',
        'email': 'demo@example.com',
        'firstName': '太郎',
        'lastName': '山田',
      },
    };

/// Go バックエンド(認証)のモック。業務 API は /ping だけ。
http.Client _mockApiClient() {
  return MockClient((request) async {
    final path = request.url.path;
    _requests.add(request);
    if (path.endsWith('/auth/config')) {
      return _json({
        'code': 0,
        'message': 'success',
        'data': {'enabled': _authEnabled},
      });
    }
    if (path.endsWith('/auth/login')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['email'] == 'outsider@gmail.com') {
        return _json({
          'code': 403,
          'message': 'this account is not allowed to sign in',
          'errorCode': 'not_allowed',
        }, 403);
      }
      if (body['email'] == 'unverified@c.tre-inc.com') {
        return _json({
          'code': 400,
          'message': 'invalid request: email_verification_required',
          'errorCode': 'email_verification_required',
        }, 400);
      }
      if (body['password'] == 'wrong') {
        return _json({
          'code': 401,
          'message': 'invalid credentials',
          'errorCode': 'invalid_credentials',
        }, 401);
      }
      return _json({
        'code': 0,
        'message': 'success',
        'data': _sessionJson('access-1', 'refresh-1'),
      });
    }
    if (path.endsWith('/auth/token')) {
      return _json({
        'code': 0,
        'message': 'success',
        'data': _sessionJson('access-g', 'refresh-g'),
      });
    }
    if (path.endsWith('/auth/refresh')) {
      return _json({
        'code': 0,
        'message': 'success',
        'data': _sessionJson('access-2', 'refresh-2'),
      });
    }
    if (path.endsWith('/auth/logout')) {
      return _json({'code': 0, 'message': 'success'});
    }
    if (path.endsWith('/auth/authorize-url')) {
      return _json({
        'code': 0,
        'message': 'success',
        'data': {'url': 'https://auth.example.com/authorize'},
      });
    }
    if (_expiredTokens.contains(request.headers['authorization'])) {
      return _json({'code': 401, 'message': 'token expired'}, 401);
    }
    if (path.endsWith('/ping')) {
      return _json({'code': 0, 'message': 'success', 'data': 'pong'});
    }
    return http.Response('not found', 404);
  });
}

/// テスト用の回答元。質問ごとに StreamController を作り、テスト側からイベントを流す。
class _FakeAiAssistant implements AiAssistant {
  final List<Map<String, Object?>> asked = [];
  final Map<String, Uint8List> images = {};
  final List<StreamController<AiEvent>> streams = [];
  final List<AiConversationSummary> conversations = [];
  final Map<String, List<AiHistoryMessage>> messages = {};
  final List<String> deleted = [];

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
  }) {
    asked.add({
      'question': question,
      'conversationId': conversationId,
      'companyCode': companyCode,
      'storeCode': storeCode,
      'imageIds': imageIds,
    });
    final controller = StreamController<AiEvent>();
    streams.add(controller);
    return controller.stream;
  }

  @override
  Future<String> uploadImage(Uint8List bytes) async {
    final id = 'img${images.length + 1}';
    images[id] = bytes;
    return id;
  }

  @override
  Future<Uint8List> loadImage(String id) async => images[id]!;

  @override
  Future<List<AiConversationSummary>> listConversations() async =>
      List.of(conversations);

  @override
  Future<List<AiHistoryMessage>> loadMessages(String conversationId) async =>
      messages[conversationId] ?? const [];

  @override
  Future<void> deleteConversation(String conversationId) async {
    deleted.add(conversationId);
    conversations.removeWhere((c) => c.id == conversationId);
  }
}

/// テスト用の読み上げ。speak の引数を記録し、テストから進み具合・終了を流す。
class _FakeSpeechOutput implements SpeechOutput {
  _FakeSpeechOutput({this.available = true});

  final bool available;
  final List<String> spoken = [];
  int stopCount = 0;
  void Function(double)? onProgress;
  void Function()? onDone;

  @override
  Future<bool> speak(
    String text, {
    required void Function(double progress) onProgress,
    required void Function() onDone,
  }) async {
    if (!available) return false;
    spoken.add(text);
    this.onProgress = onProgress;
    this.onDone = onDone;
    return true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final done = onDone;
    onDone = null;
    done?.call();
  }
}

/// テスト用の認識エンジン。テストから 1 区切りの結果・状態・エラーを流す。
class _FakeSpeechEngine implements SpeechEngine {
  late void Function(String status) onStatus;
  late void Function(String error) onError;
  void Function(String words, bool isFinal)? onResult;
  int listenCount = 0;
  int stopCount = 0;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error) onError,
  }) async {
    this.onStatus = onStatus;
    this.onError = onError;
    return true;
  }

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String words, bool isFinal) onResult,
  }) async {
    listenCount++;
    this.onResult = onResult;
  }

  @override
  Future<void> stop() async => stopCount++;

  /// 1 区切りを「words を話して終わった」ことにする。
  void say(String words) {
    onResult!(words, false);
    onResult!(words, true);
    onStatus('notListening');
    onStatus('done');
  }
}

/// ApiClient.authDelegate の差し替え。refresh で token を入れ替える。
class _FakeAuthDelegate implements ApiAuthDelegate {
  _FakeAuthDelegate(this.accessToken);

  @override
  String? accessToken;
  int refreshCount = 0;
  bool unauthorized = false;

  @override
  Future<bool> refreshAccessToken() async {
    refreshCount++;
    accessToken = 'fresh-token';
    return true;
  }

  @override
  void onUnauthorized() => unauthorized = true;
}

http.StreamedResponse _sse(List<Map<String, dynamic>> events) {
  final body = events.map((e) => 'data: ${jsonEncode(e)}\n\n').join();
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

/// AI 画面の最初の表示(会話が無いとき)にある文言。
const _welcome = '何を分析しますか？';

void main() {
  setUp(() {
    // 光球・オーロラなどの繰り返しアニメーションを止める(pumpAndSettle が終わらないため)
    TechMotion.enabled = false;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AuthManager.instance = AuthManager();
    _requests.clear();
    _authEnabled = true;
    _expiredTokens.clear();
    SpeechOutputLocator.set(_FakeSpeechOutput());
    // 既定は本番の agent なので、テストではデモデータの回答元にしておく
    AiAssistantLocator.set(const MockAiAssistant());
    ApiClientLocator.set(ApiClient(_mockApiClient()));
  });

  tearDown(() {
    ApiClientLocator.reset();
    AiAssistantLocator.reset();
    SpeechOutputLocator.reset();
    BarcodeScanLauncher.reset();
    PhotoPickerLauncher.reset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const AiPacerApp());
    // _SessionGate が保存領域を読んでから、ログイン画面か AI 画面を出す
    await tester.pumpAndSettle();
  }

  Future<void> login(
    WidgetTester tester, {
    String email = 'demo@example.com',
    String password = 'password',
  }) async {
    await tester.enterText(find.byType(TextFormField).at(0), email);
    await tester.enterText(find.byType(TextFormField).at(1), password);
    await tester.tap(find.widgetWithText(NeonButton, 'ログイン'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// ログインを飛ばして AI 画面から始める。
  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(const AiPacerApp(home: AiChatPage()));
    await tester.pumpAndSettle();
  }

  Future<void> ask(WidgetTester tester, String question) async {
    await tester.enterText(find.byType(TextField), question);
    await tester.tap(find.byTooltip('送信'));
    await tester.pump();
  }

  // -------------------------------------------------------------------------
  // ログイン・起動
  // -------------------------------------------------------------------------

  testWidgets('login page renders the sign-in form', (tester) async {
    await pumpApp(tester);
    expect(find.text('AI PACER'), findsOneWidget);
    expect(find.text('ログイン'), findsNWidgets(2)); // 見出しとボタン
    expect(find.text('メールアドレス'), findsOneWidget);
    expect(find.text('パスワード'), findsOneWidget);
    expect(find.text('ログイン状態を保持する'), findsOneWidget);
    expect(find.byTooltip('Microsoftでログイン'), findsOneWidget);
    expect(find.byTooltip('Googleでログイン'), findsOneWidget);
  });

  testWidgets('password visibility button toggles obscuring', (tester) async {
    await pumpApp(tester);
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  });

  testWidgets('empty form shows validation messages', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(NeonButton, 'ログイン'));
    await tester.pump();
    expect(find.text('メールアドレスを入力してください'), findsOneWidget);
    expect(find.text('パスワードを入力してください'), findsOneWidget);
    expect(_requests, isEmpty);
  });

  testWidgets('password login goes straight to the AI screen', (tester) async {
    await pumpApp(tester);
    await login(tester);
    await tester.pumpAndSettle();
    expect(find.text(_welcome), findsOneWidget);
    expect(find.text('メールアドレス'), findsNothing);

    final loginReq =
        _requests.firstWhere((r) => r.url.path.endsWith('/auth/login'));
    expect(jsonDecode(loginReq.body), {
      'email': 'demo@example.com',
      'password': 'password',
    });
    expect(loginReq.headers['authorization'], isNull);
    expect(AuthManager.instance.session?.user.email, 'demo@example.com');
    // 企業の選択は無い
    expect(_requests.where((r) => r.url.path.endsWith('/companies')), isEmpty);
  });

  testWidgets('wrong password shows an error and stays on login',
      (tester) async {
    await pumpApp(tester);
    await login(tester, password: 'wrong');
    await tester.pumpAndSettle();
    expect(find.text('メールアドレスまたはパスワードが正しくありません'), findsOneWidget);
    expect(find.text(_welcome), findsNothing);
    expect(AuthManager.instance.isSignedIn, isFalse);
  });

  testWidgets('account outside the allowlist is rejected', (tester) async {
    await pumpApp(tester);
    await login(tester, email: 'outsider@gmail.com');
    await tester.pumpAndSettle();
    expect(
      find.text('このアカウントではログインできません。会社のメールアドレスでログインしてください'),
      findsOneWidget,
    );
    expect(find.text(_welcome), findsNothing);
    expect(AuthManager.instance.isSignedIn, isFalse);
  });

  testWidgets('unverified email asks the user to contact an admin',
      (tester) async {
    await pumpApp(tester);
    await login(tester, email: 'unverified@c.tre-inc.com');
    await tester.pumpAndSettle();
    expect(find.text('メールアドレスの確認が完了していません。管理者にお問い合わせください'), findsOneWidget);
    expect(AuthManager.instance.isSignedIn, isFalse);
  });

  testWidgets('auth disabled on backend enters directly and is remembered',
      (tester) async {
    _authEnabled = false;
    await pumpApp(tester);
    await login(tester);
    await tester.pumpAndSettle();
    expect(find.text(_welcome), findsOneWidget);
    expect(_requests.where((r) => r.url.path.endsWith('/auth/login')), isEmpty);

    // 次の起動でもログイン画面を出さない
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApp(tester);
    expect(find.text(_welcome), findsOneWidget);
  });

  testWidgets('saved session skips the login page', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'auth.session': jsonEncode(_sessionJson('access-1', 'refresh-1')),
    });
    await pumpApp(tester);
    expect(find.text('メールアドレス'), findsNothing);
    expect(find.text(_welcome), findsOneWidget);
  });

  testWidgets('no saved token starts at the login page', (tester) async {
    await pumpApp(tester);
    expect(find.text('メールアドレス'), findsOneWidget);
  });

  testWidgets('expired access token is refreshed and the request retried',
      (tester) async {
    _expiredTokens.add('Bearer access-old');
    FlutterSecureStorage.setMockInitialValues({
      'auth.session': jsonEncode(_sessionJson('access-old', 'refresh-old')),
    });
    await pumpApp(tester);
    expect(find.text(_welcome), findsOneWidget);

    expect(await ApiClientLocator.instance.get('/ping'),
        containsPair('data', 'pong'));
    final refreshes =
        _requests.where((r) => r.url.path.endsWith('/auth/refresh')).toList();
    expect(refreshes, hasLength(1));
    expect(jsonDecode(refreshes.single.body), {'refreshToken': 'refresh-old'});
    final pingReq = _requests.lastWhere((r) => r.url.path.endsWith('/ping'));
    expect(pingReq.headers['authorization'], 'Bearer access-2');
  });

  testWidgets('google login completes the OAuth flow via the backend',
      (tester) async {
    // 偽のブラウザ:authorize-url に送った state をそのまま返す
    String? openedUrl;
    AuthManager.instance = AuthManager(
      gateway: BackendAuthGateway(webAuthenticate: (url, scheme) async {
        openedUrl = url;
        final req = _requests
            .lastWhere((r) => r.url.path.endsWith('/auth/authorize-url'));
        final state = (jsonDecode(req.body) as Map)['state'];
        return '$scheme://auth/callback?code=code-123&state=$state';
      }),
    );
    await pumpApp(tester);
    await tester.ensureVisible(find.byTooltip('Googleでログイン'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Googleでログイン'));
    await tester.pumpAndSettle();

    final authReq =
        _requests.lastWhere((r) => r.url.path.endsWith('/auth/authorize-url'));
    final authBody = jsonDecode(authReq.body) as Map<String, dynamic>;
    expect(authBody['provider'], 'GoogleOAuth');
    expect(authBody['redirectUri'], 'com.retailai.mdlink://auth/callback');
    expect(openedUrl, 'https://auth.example.com/authorize');

    final tokenReq =
        _requests.lastWhere((r) => r.url.path.endsWith('/auth/token'));
    final tokenBody = jsonDecode(tokenReq.body) as Map<String, dynamic>;
    expect(tokenBody['code'], 'code-123');
    expect(tokenBody['codeVerifier'], isNotEmpty);

    expect(AuthManager.instance.session?.accessToken, 'access-g');
    expect(find.text(_welcome), findsOneWidget);
  });

  testWidgets('google login rejects a callback with a mismatched state',
      (tester) async {
    AuthManager.instance = AuthManager(
      gateway: BackendAuthGateway(
        webAuthenticate: (url, scheme) async =>
            '$scheme://auth/callback?code=code-123&state=forged',
      ),
    );
    await pumpApp(tester);
    await tester.ensureVisible(find.byTooltip('Googleでログイン'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Googleでログイン'));
    await tester.pumpAndSettle();

    expect(find.text('ログイン状態が一致しません。もう一度お試しください'), findsOneWidget);
    expect(_requests.where((r) => r.url.path.endsWith('/auth/token')), isEmpty);
    expect(AuthManager.instance.isSignedIn, isFalse);
  });

  Future<void> openLogoutDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('アカウント'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ログアウト'));
    await tester.pumpAndSettle();
    expect(find.text('ログアウトしますか？'), findsOneWidget);
  }

  testWidgets('logout revokes the session and forgets the conversation',
      (tester) async {
    await AuthManager.instance.setSession(
        AuthSession.fromJson(_sessionJson('access-1', 'r')),
        persist: true);
    SharedPreferences.setMockInitialValues({'ai.lastConversationId': 'c-1'});
    await pumpChat(tester);

    // アカウントメニューに利用者が出る
    await tester.tap(find.byTooltip('アカウント'));
    await tester.pumpAndSettle();
    expect(find.text('山田 太郎'), findsOneWidget);
    expect(find.text('demo@example.com'), findsOneWidget);
    await tester.tap(find.text('ログアウト'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'ログアウト'));
    await tester.pumpAndSettle();

    final logoutReq =
        _requests.lastWhere((r) => r.url.path.endsWith('/auth/logout'));
    expect(logoutReq.headers['authorization'], 'Bearer access-1');
    expect(AuthManager.instance.isSignedIn, isFalse);
    expect(find.text('メールアドレス'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ai.lastConversationId'), isNull);
  });

  testWidgets('logout dialog can be cancelled', (tester) async {
    await pumpChat(tester);
    await openLogoutDialog(tester);
    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();
    expect(find.text(_welcome), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // AI の回答元
  // -------------------------------------------------------------------------

  test('default assistant is the production agent', () {
    AiAssistantLocator.reset();
    expect(AiAssistantLocator.instance, isA<BackendAiAssistant>());
    expect(AiAssistantLocator.agentBaseUrl,
        'https://mdlink-mobile-app-agent-cjy6246wiq-an.a.run.app/api/v1/ai');
  });

  test('BackendAiAssistant streams SSE events with the bearer token',
      () async {
    final saved = ApiClient.authDelegate;
    addTearDown(() => ApiClient.authDelegate = saved);
    ApiClient.authDelegate = _FakeAuthDelegate('token-1');

    late http.BaseRequest sent;
    late Map<String, dynamic> sentBody;
    final assistant = BackendAiAssistant(
      baseUrl: 'https://agent.example/api/v1/ai/',
      client: MockClient.streaming((request, body) async {
        sent = request;
        sentBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return _sse([
          {'type': 'start', 'conversationId': 'c-1', 'questionId': 1},
          {
            'type': 'tool',
            'name': 'get_store_sales_progress',
            'status': 'running'
          },
          {
            'type': 'tool',
            'name': 'get_store_sales_progress',
            'status': 'done'
          },
          {'type': 'text', 'text': '売上は'},
          {'type': 'text', 'text': '386万円です。'},
          {'type': 'unknown'},
          {'type': 'done', 'conversationId': 'c-1'},
        ]);
      }),
    );

    final events = await assistant.ask('67番の売上は？').toList();

    expect(sent.url.toString(), 'https://agent.example/api/v1/ai/chat');
    expect(sent.headers['Authorization'], 'Bearer token-1');
    // 企業・店舗は送らない
    expect(sentBody, {'message': '67番の売上は？'});
    expect(events.first, isA<AiStarted>());
    expect((events.first as AiStarted).conversationId, 'c-1');
    expect(
      events.whereType<AiTextDelta>().map((e) => e.text).join(),
      '売上は386万円です。',
    );
    expect(events.whereType<AiToolProgress>().map((e) => e.status),
        ['running', 'done']);
    expect(events.last, isA<AiFinished>());
  });

  test('BackendAiAssistant refreshes the token once on 401', () async {
    final saved = ApiClient.authDelegate;
    addTearDown(() => ApiClient.authDelegate = saved);
    final auth = _FakeAuthDelegate('expired');
    ApiClient.authDelegate = auth;

    final tokens = <String?>[];
    final assistant = BackendAiAssistant(
      baseUrl: 'https://agent.example/api/v1/ai',
      client: MockClient((request) async {
        tokens.add(request.headers['Authorization']);
        if (request.headers['Authorization'] == 'Bearer expired') {
          return http.Response('{"code":401}', 401);
        }
        return http.Response(
          jsonEncode({
            'code': 0,
            'message': 'success',
            'data': [
              {
                'id': 'c-1',
                'title': '67番の売上',
                'storeCode': '0067',
                'createdAt': '2026-10-13T01:00:00+00:00',
                'updatedAt': '2026-10-13T02:00:00+00:00',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final list = await assistant.listConversations();
    expect(tokens, ['Bearer expired', 'Bearer fresh-token']);
    expect(auth.refreshCount, 1);
    expect(auth.unauthorized, isFalse);
    expect(list.single.title, '67番の売上');
    expect(list.single.storeCode, '0067');
  });

  // -------------------------------------------------------------------------
  // AI 画面
  // -------------------------------------------------------------------------

  testWidgets('AI answers a suggested prompt with demo data', (tester) async {
    await pumpChat(tester);
    expect(find.text(_welcome), findsOneWidget);
    expect(find.text('ONLINE'), findsOneWidget);

    await tester.ensureVisible(find.text('売上の推移'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('売上の推移'));
    await tester.pump();
    expect(find.text(_welcome), findsNothing);
    expect(find.text('67番店舗の今月の日別売上の推移は？'), findsOneWidget); // 吹き出し
    expect(find.text('回答を作成中…'), findsOneWidget);
    expect(find.text('THINKING'), findsOneWidget);

    // MockAiAssistant は 600ms 待ってから答える
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('回答を作成中…'), findsNothing);
    expect(find.text('PACER AI'), findsOneWidget);
    expect(find.text('デモデータ'), findsOneWidget);
    expect(find.text('ONLINE'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('カテゴリ別売上推移'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('カテゴリ別売上推移'), findsOneWidget);
  });

  testWidgets('AI clears the input after sending', (tester) async {
    await pumpChat(tester);
    await ask(tester, '在庫を教えて');
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(find.text('在庫を教えて'), findsOneWidget); // 吹き出しにだけ出る

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('AI streams the answer and continues the conversation',
      (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    await pumpChat(tester);

    await ask(tester, '67番の昨日の売上は？');
    expect(fake.asked.single['conversationId'], isNull);
    // 企業・店舗は選ばないので送らない
    expect(fake.asked.single['companyCode'], isNull);
    expect(fake.asked.single['storeCode'], isNull);
    expect(find.text('回答を作成中…'), findsOneWidget);

    final first = fake.streams.single;
    first.add(const AiStarted('c-1'));
    first.add(const AiToolProgress('get_store_sales_progress', 'running'));
    await tester.pump();
    expect(find.text('「店舗の売上」を取得中…'), findsOneWidget);

    first.add(const AiToolProgress('get_store_sales_progress', 'done'));
    first.add(const AiTextDelta('売上は'));
    first.add(const AiTextDelta('386万円です。'));
    await tester.pump();
    expect(find.textContaining('売上は386万円です。', findRichText: true),
        findsOneWidget);

    first.add(const AiFinished());
    await first.close();
    await tester.pumpAndSettle();
    expect(find.text('売上は386万円です。'), findsOneWidget);
    expect(find.text('デモデータ'), findsNothing);

    // 同じ会話で続けて質問すると conversationId が引き継がれる
    await ask(tester, '先週と比べて？');
    expect(fake.asked.last['conversationId'], 'c-1');
    fake.streams.last
      ..add(const AiFailed('エラーが発生したため回答できませんでした。'))
      ..close();
    await tester.pumpAndSettle();
    expect(find.text('エラーが発生したため回答できませんでした。'), findsOneWidget);

    // 新しい会話で最初の画面に戻り、次の質問は新しい会話になる
    await tester.tap(find.byTooltip('新しい会話'));
    await tester.pumpAndSettle();
    expect(find.text('売上は386万円です。'), findsNothing);
    expect(find.text(_welcome), findsOneWidget);
    await tester.ensureVisible(find.text('部門別の達成率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('部門別の達成率'));
    await tester.pump();
    expect(fake.asked.last['question'], '67番店舗の昨日の部門別の予算達成率は？');
    expect(fake.asked.last['conversationId'], isNull);
    await fake.streams.last.close();
    await tester.pumpAndSettle();
  });

  testWidgets('AI reopens the last conversation at the latest message',
      (tester) async {
    final fake = _FakeAiAssistant()
      ..messages['c-1'] = [
        for (var i = 0; i < 12; i++) ...[
          AiHistoryMessage(
              isUser: true, text: '質問$i', createdAt: DateTime(2026, 10, 15)),
          AiHistoryMessage(
              isUser: false,
              text: '回答$i\n2 行目\n3 行目',
              createdAt: DateTime(2026, 10, 15)),
        ],
      ];
    AiAssistantLocator.set(fake);
    SharedPreferences.setMockInitialValues({'ai.lastConversationId': 'c-1'});
    await pumpChat(tester);

    expect(find.text(_welcome), findsNothing);
    expect(find.text('回答11\n2 行目\n3 行目'), findsOneWidget);
    expect(tester.getRect(find.text('回答11\n2 行目\n3 行目')).bottom,
        lessThan(tester.getTopLeft(find.byTooltip('送信')).dy));

    // 続けて聞くと同じ会話になる
    await ask(tester, '今月は？');
    expect(fake.asked.last['conversationId'], 'c-1');
    await fake.streams.last.close();
    await tester.pumpAndSettle();
  });

  testWidgets('AI conversation id is kept across app restarts',
      (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    await pumpChat(tester);

    await ask(tester, '昨日の売上は？');
    fake.streams.single
      ..add(const AiStarted('c-1'))
      ..add(const AiTextDelta('売上は386万円です。'))
      ..add(const AiFinished());
    await fake.streams.single.close();
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ai.lastConversationId'), 'c-1');

    // アプリを開き直すと、前回の会話を読み込んで続ける
    fake.messages['c-1'] = [
      AiHistoryMessage(
          isUser: true, text: '昨日の売上は？', createdAt: DateTime(2026, 10, 15)),
      AiHistoryMessage(
          isUser: false,
          text: '売上は386万円です。',
          createdAt: DateTime(2026, 10, 15)),
    ];
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpChat(tester);
    expect(find.text('売上は386万円です。'), findsOneWidget);

    // 「新しい会話」を押したら、次に開いたときは空から始める
    await tester.tap(find.byTooltip('新しい会話'));
    await tester.pumpAndSettle();
    expect(prefs.getString('ai.lastConversationId'), isNull);
  });

  testWidgets('AI reopens and deletes conversations from history',
      (tester) async {
    final fake = _FakeAiAssistant()
      ..conversations.addAll([
        AiConversationSummary(
          id: 'c-1',
          title: '67番の売上',
          storeCode: '0067',
          updatedAt: DateTime(2026, 10, 12, 9, 30),
        ),
        AiConversationSummary(
          id: 'c-2',
          title: '在庫の確認',
          updatedAt: DateTime(2026, 10, 11, 18),
        ),
      ])
      ..messages['c-1'] = [
        AiHistoryMessage(
            isUser: true,
            text: '67番の売上は？',
            createdAt: DateTime(2026, 10, 12, 9)),
        AiHistoryMessage(
            isUser: false,
            text: '0067 の売上は 385万円です。',
            createdAt: DateTime(2026, 10, 12, 9, 1)),
      ];
    AiAssistantLocator.set(fake);
    await pumpChat(tester);

    await tester.tap(find.byTooltip('会話履歴'));
    await tester.pumpAndSettle();
    expect(find.text('67番の売上'), findsOneWidget);
    expect(find.text('10/12 09:30  ·  店舗 0067'), findsOneWidget);

    // ゴミ箱で 2 件目を削除
    await tester.tap(find.byTooltip('削除').last);
    await tester.pumpAndSettle();
    expect(fake.deleted, ['c-2']);
    expect(find.text('在庫の確認'), findsNothing);

    // 1 件目を開くと履歴が表示され、続きの質問は同じ会話になる
    await tester.tap(find.text('67番の売上'));
    await tester.pumpAndSettle();
    expect(find.text('67番の売上は？'), findsOneWidget);
    expect(find.text('0067 の売上は 385万円です。'), findsOneWidget);

    await ask(tester, '昨日は？');
    expect(fake.asked.single['conversationId'], 'c-1');
    await fake.streams.single.close();
    await tester.pumpAndSettle();
  });

  test('narrationText removes bullets and markdown for speech', () {
    expect(
      narrationText('67番の売上は10,704,000円です。\n\n・予算達成率：90.7%\n- **昨年対比**：94.9%'),
      '67番の売上は10,704,000円です。予算達成率：90.7%。昨年対比：94.9%。',
    );
    expect(narrationText('  \n '), isEmpty);
    expect(narrationText('あ' * 5000).length, 3900);
  });

  testWidgets('AI answer is read aloud automatically and can be stopped',
      (tester) async {
    final fake = _FakeAiAssistant();
    final speech = _FakeSpeechOutput();
    AiAssistantLocator.set(fake);
    SpeechOutputLocator.set(speech);
    await pumpChat(tester);
    expect(find.byTooltip('自動読み上げ:オン'), findsOneWidget);

    await ask(tester, '昨日の売上は？');
    fake.streams.single
      ..add(const AiTextDelta('売上は'))
      ..add(const AiTextDelta('386万円です。'));
    await tester.pump();
    // 受信中は読み上げない
    expect(find.byTooltip('読み上げ'), findsNothing);
    expect(speech.spoken, isEmpty);
    fake.streams.single
      ..add(const AiFinished())
      ..close();
    await tester.pumpAndSettle();

    // 届き終わったら自動で読み上げる
    expect(speech.spoken, ['売上は386万円です。']);
    expect(find.text('読み上げ中…'), findsOneWidget);
    speech.onProgress!(0.5);
    await tester.pump();

    // ■ で止まる
    await tester.tap(find.byTooltip('読み上げを停止'));
    await tester.pump();
    expect(speech.stopCount, 1);
    expect(find.text('音声読み上げ'), findsOneWidget);

    // ▶ でもう一度読める。最後まで読むと元に戻る
    await tester.tap(find.byTooltip('読み上げ'));
    await tester.pump();
    expect(speech.spoken, hasLength(2));
    speech.onDone!();
    await tester.pump();
    expect(find.text('読み上げ中…'), findsNothing);

    // 読み上げ中に次の質問を送ると止まる
    await tester.tap(find.byTooltip('読み上げ'));
    await tester.pump();
    await ask(tester, '先週は？');
    expect(speech.stopCount, 2);
    // エラーの回答は自動で読まない
    fake.streams.last
      ..add(const AiFailed('エラーが発生したため回答できませんでした。'))
      ..close();
    await tester.pumpAndSettle();
    expect(speech.spoken, hasLength(3));
  });

  testWidgets('AI auto read-aloud can be turned off and is remembered',
      (tester) async {
    final fake = _FakeAiAssistant();
    final speech = _FakeSpeechOutput();
    AiAssistantLocator.set(fake);
    SpeechOutputLocator.set(speech);
    await pumpChat(tester);

    await tester.tap(find.byTooltip('自動読み上げ:オン'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('自動読み上げ:オフ'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ai.autoSpeak'), isFalse);
    // 案内の SnackBar が送信ボタンに重なるので、消えるまで待つ
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await ask(tester, '昨日の売上は？');
    fake.streams.single
      ..add(const AiTextDelta('売上は386万円です。'))
      ..add(const AiFinished())
      ..close();
    await tester.pumpAndSettle();
    expect(speech.spoken, isEmpty);
    // 手動の ▶ は使える
    await tester.tap(find.byTooltip('読み上げ'));
    await tester.pump();
    expect(speech.spoken, ['売上は386万円です。']);
  });

  testWidgets('AI read-aloud reports when TTS is unavailable', (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    SpeechOutputLocator.set(_FakeSpeechOutput(available: false));
    await pumpChat(tester);

    await ask(tester, '昨日の売上は？');
    fake.streams.single
      ..add(const AiTextDelta('売上は386万円です。'))
      ..add(const AiFinished())
      ..close();
    await tester.pumpAndSettle();

    expect(find.textContaining('音声読み上げを利用できません'), findsOneWidget);
    expect(find.text('読み上げ中…'), findsNothing);
  });

  group('ContinuousVoiceInput', () {
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('keeps listening across pauses and joins the segments', () async {
      final engine = _FakeSpeechEngine();
      final input =
          ContinuousVoiceInput(engine: engine, restartDelay: Duration.zero);
      final texts = <String>[];
      final done = <String?>[];
      expect(
        await input.start(onResult: (t, _) => texts.add(t), onDone: done.add),
        isTrue,
      );

      engine.say('67番店舗の');
      await settle();
      expect(engine.listenCount, 2); // 間が空いても次の区切りを自動で始める
      expect(done, isEmpty);

      engine.onResult!('昨日の売上', false);
      expect(texts.last, '67番店舗の昨日の売上');
      engine.say('昨日の売上を教えて');
      await settle();
      expect(texts.last, '67番店舗の昨日の売上を教えて');

      // 次の区切りで何も話さなければ終わる(エラーにはしない)
      engine.onError('error_speech_timeout');
      engine.onStatus('done');
      await settle();
      expect(done, [null]);
      expect(engine.listenCount, 3);
    });

    test('stops when the user taps the mic again', () async {
      final engine = _FakeSpeechEngine();
      final input =
          ContinuousVoiceInput(engine: engine, restartDelay: Duration.zero);
      final done = <String?>[];
      final texts = <String>[];
      await input.start(onResult: (t, _) => texts.add(t), onDone: done.add);
      engine.onResult!('在庫を', false);

      await input.stop();
      engine.onStatus('done'); // 停止後に届く状態は無視される
      await settle();
      expect(engine.stopCount, 1);
      expect(done, [null]);
      expect(engine.listenCount, 1);
      expect(texts.last, '在庫を');
    });

    test('ends at the total time limit and reports real errors', () async {
      var now = DateTime(2026, 10, 13, 10);
      final engine = _FakeSpeechEngine();
      final input = ContinuousVoiceInput(
        engine: engine,
        restartDelay: Duration.zero,
        maxDuration: const Duration(seconds: 60),
        clock: () => now,
      );
      final done = <String?>[];
      await input.start(onResult: (_, __) {}, onDone: done.add);
      now = now.add(const Duration(seconds: 61));
      engine.say('長い質問');
      await settle();
      expect(done, [null]);
      expect(engine.listenCount, 1);

      // 2 回目の入力:権限やネットワークのエラーはそのまま伝える
      final done2 = <String?>[];
      await input.start(onResult: (_, __) {}, onDone: done2.add);
      engine.onError('error_network');
      engine.onStatus('done');
      expect(done2, ['error_network']);
    });
  });

  test('chart events are parsed and values are formatted for display', () {
    final event = AiEvent.fromJson({
      'type': 'chart',
      'chart': {
        'type': 'hbar',
        'title': '部門別の予算達成率',
        'unit': '%',
        'labels': ['青果', '精肉'],
        'series': [
          {
            'name': '達成率',
            'values': [102.5, null],
          },
        ],
        'reference': {'value': 100, 'label': '予算'},
      },
    });
    final chart = (event as AiChartReceived).chart;
    expect(chart.type, AiChartType.hbar);
    expect(chart.series.single.values, [102.5, null]);
    expect(chart.referenceValue, 100);

    expect(formatChartValue(10704000, '円'), '10,704,000円');
    expect(formatChartValue(85.14, '%'), '85.1%');
    expect(formatAxisValue(10704000, '円'), '1070万');
    expect(formatAxisValue(113450000, '円'), '1.1億');
    expect(formatAxisValue(5000, '個'), '5,000');
  });

  testWidgets('AI answer shows line, bar and horizontal bar charts',
      (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    await pumpChat(tester);

    await ask(tester, '今月の推移と部門別は？');
    final stream = fake.streams.single;
    // グラフが先に届いても「作成中」ではなく回答カードを出す
    stream.add(const AiChartReceived(AiChart(
      type: AiChartType.line,
      title: '10月の日別売上',
      unit: '円',
      labels: ['10/1', '10/2', '10/3'],
      series: [
        AiChartSeries(name: '今年', values: [100, 200, 150]),
        AiChartSeries(name: '予算', values: [150, 150, 150]),
      ],
    )));
    await tester.pump();
    expect(find.text('回答を作成中…'), findsNothing);
    expect(find.text('10月の日別売上'), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget);
    // 系列が 2 つなら凡例を出す
    expect(find.text('今年'), findsOneWidget);
    expect(find.text('予算'), findsOneWidget);

    stream
      ..add(const AiChartReceived(AiChart(
        type: AiChartType.bar,
        title: '店舗比較',
        unit: '円',
        labels: ['67福岡空港', '458月寒'],
        series: [
          AiChartSeries(name: '売上', values: [10704000, 8797000]),
        ],
      )))
      ..add(const AiChartReceived(AiChart(
        type: AiChartType.hbar,
        title: '部門別の予算達成率',
        unit: '%',
        labels: ['青果', '精肉'],
        series: [
          AiChartSeries(name: '達成率', values: [102.5, 91]),
        ],
        referenceValue: 100,
        referenceLabel: '予算',
      )))
      ..add(const AiTextDelta('今月は予算を少し下回っています。'))
      ..add(const AiFinished());
    await stream.close();
    await tester.pumpAndSettle();

    // 会話のリストを指定してスクロールする(画面には他にもスクロール領域がある)
    await tester.scrollUntilVisible(
      find.text('部門別の予算達成率'),
      200,
      scrollable: find
          .ancestor(of: find.text('店舗比較'), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('店舗比較'), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    expect(find.text('102.5%'), findsOneWidget);
    expect(find.text('91.0%'), findsOneWidget);
    expect(find.text('┆ 予算(100.0%)'), findsOneWidget);
    expect(find.text('今月は予算を少し下回っています。'), findsOneWidget);
  });

  testWidgets('AI history shows saved charts', (tester) async {
    final fake = _FakeAiAssistant()
      ..conversations.add(AiConversationSummary(
        id: 'c-1',
        title: '部門別',
        updatedAt: DateTime(2026, 10, 12, 9),
      ))
      ..messages['c-1'] = [
        AiHistoryMessage(
            isUser: true, text: '部門別は？', createdAt: DateTime(2026, 10, 12, 9)),
        AiHistoryMessage(
          isUser: false,
          text: '青果が好調です。',
          createdAt: DateTime(2026, 10, 12, 9, 1),
          charts: const [
            AiChart(
              type: AiChartType.hbar,
              title: '部門別の予算達成率',
              unit: '%',
              labels: ['青果'],
              series: [
                AiChartSeries(name: '達成率', values: [102.5]),
              ],
            ),
          ],
        ),
      ];
    AiAssistantLocator.set(fake);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('会話履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('部門別'));
    await tester.pumpAndSettle();

    expect(find.text('部門別の予算達成率'), findsOneWidget);
    expect(find.text('102.5%'), findsOneWidget);
  });

  testWidgets('AI follow-up suggestions are tappable on the latest answer',
      (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    await pumpChat(tester);

    await ask(tester, '部門別は？');
    fake.streams.single
      ..add(const AiStarted('c-1'))
      ..add(const AiSuggestionsReceived(['最初の候補']))
      ..add(const AiSuggestionsReceived(['青果の推移は？', '昨年と比べて']))
      ..add(const AiTextDelta('青果が好調です。'));
    await tester.pump();
    // 受信中は出さない
    expect(find.text('青果の推移は？'), findsNothing);
    fake.streams.single.add(const AiFinished());
    await fake.streams.single.close();
    await tester.pumpAndSettle();
    expect(find.text('最初の候補'), findsNothing); // 後から届いた候補で置き換わる
    expect(find.text('昨年と比べて'), findsOneWidget);

    // タップでそのまま同じ会話の質問として送る
    await tester.tap(find.text('青果の推移は？'));
    await tester.pump();
    expect(fake.asked.last['question'], '青果の推移は？');
    expect(fake.asked.last['conversationId'], 'c-1');
    fake.streams.last
      ..add(const AiTextDelta('青果は伸びています。'))
      ..add(const AiFinished());
    await fake.streams.last.close();
    await tester.pumpAndSettle();
    // 古い回答の候補は消える
    expect(find.text('昨年と比べて'), findsNothing);
  });

  testWidgets('AI history shows suggestions for the last answer',
      (tester) async {
    final fake = _FakeAiAssistant()
      ..conversations.add(AiConversationSummary(
        id: 'c-1',
        title: '部門別',
        updatedAt: DateTime(2026, 10, 12, 9),
      ))
      ..messages['c-1'] = [
        AiHistoryMessage(
            isUser: true, text: '部門別は？', createdAt: DateTime(2026, 10, 12, 9)),
        AiHistoryMessage(
          isUser: false,
          text: '青果が好調です。',
          createdAt: DateTime(2026, 10, 12, 9, 1),
          suggestions: const ['精肉の推移は？'],
        ),
      ];
    AiAssistantLocator.set(fake);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('会話履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('部門別'));
    await tester.pumpAndSettle();
    expect(find.text('精肉の推移は？'), findsOneWidget);
  });

  testWidgets('AI input "+" attaches photos and sends them with the question',
      (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    final picked = <PhotoSource>[];
    PhotoPickerLauncher.pick = (source) async {
      picked.add(source);
      return _tinyPng;
    };
    await pumpChat(tester);

    Future<void> choose(String label) async {
      await tester.tap(find.byTooltip('その他の入力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await choose('写真を撮る');
    await choose('写真を選ぶ');
    await choose('写真を選ぶ');
    expect(picked,
        [PhotoSource.camera, PhotoSource.gallery, PhotoSource.gallery]);
    expect(find.byTooltip('写真を外す'), findsNWidgets(3));

    // 3 枚までなので、メニューの写真の項目は押せない
    await tester.tap(find.byTooltip('その他の入力'));
    await tester.pumpAndSettle();
    expect(find.text('写真は 3 枚までです'), findsOneWidget);
    await tester.tap(find.text('写真を選ぶ'));
    await tester.pumpAndSettle();
    expect(picked, hasLength(3));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 1 枚外してから、写真と文字を送る
    await tester.tap(find.byTooltip('写真を外す').first);
    await tester.pump();
    expect(find.byTooltip('写真を外す'), findsNWidgets(2));
    await ask(tester, 'この棚の欠品は？');
    await tester.pump();
    expect(fake.images.keys, ['img1', 'img2']);
    expect(fake.asked.single['question'], 'この棚の欠品は？');
    expect(fake.asked.single['imageIds'], ['img1', 'img2']);
    expect(find.byTooltip('写真を外す'), findsNothing);
    fake.streams.single.add(const AiTextDelta('2 段目に空きがあります'));
    await fake.streams.single.close();
    await tester.pumpAndSettle();
    expect(find.text('2 段目に空きがあります'), findsOneWidget);
  });

  testWidgets('AI chat sends a photo without text and shows history photos',
      (tester) async {
    final fake = _FakeAiAssistant()
      ..images['old1'] = _tinyPng
      ..conversations.add(AiConversationSummary(
        id: 'c1',
        title: '写真についての質問',
        updatedAt: DateTime(2026, 10, 15, 9),
      ))
      ..messages['c1'] = [
        AiHistoryMessage(
          isUser: true,
          text: '',
          createdAt: DateTime(2026, 10, 15, 9),
          imageIds: const ['old1'],
        ),
        AiHistoryMessage(
          isUser: false,
          text: '飲料の棚ですね',
          createdAt: DateTime(2026, 10, 15, 9),
        ),
      ];
    AiAssistantLocator.set(fake);
    PhotoPickerLauncher.pick = (_) async => _tinyPng;
    await pumpChat(tester);

    await tester.tap(find.byTooltip('会話履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真についての質問'));
    await tester.pumpAndSettle();
    expect(find.text('飲料の棚ですね'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byTooltip('その他の入力'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('送信'));
    await tester.pump();
    await tester.pump();
    expect(fake.asked.single['question'], '');
    expect(fake.asked.single['conversationId'], 'c1');
    expect(fake.asked.single['imageIds'], ['img2']);
    await fake.streams.single.close();
    await tester.pumpAndSettle();
  });

  testWidgets('AI input "+" scans a barcode into the text field',
      (tester) async {
    AiAssistantLocator.set(_FakeAiAssistant());
    final scans = <String?>['4901411018501', null, '45091353'];
    BarcodeScanLauncher.open = (_) async => scans.removeAt(0);
    await pumpChat(tester);

    TextField field() => tester.widget<TextField>(find.byType(TextField));

    Future<void> scan() async {
      await tester.tap(find.byTooltip('その他の入力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('バーコードをスキャン'));
      await tester.pumpAndSettle();
    }

    // 空の入力欄にはコードだけを入れる
    await scan();
    expect(field().controller!.text, '4901411018501');

    // スキャンを閉じたときは変えない
    await scan();
    expect(field().controller!.text, '4901411018501');

    // 文字の後ろに入れるときは半角スペースで区切る
    await tester.enterText(find.byType(TextField), 'この商品と');
    await scan();
    expect(field().controller!.text, 'この商品と 45091353');
  });

  testWidgets('AI input accepts multiple lines and sends them as one question',
      (tester) async {
    final fake = _FakeAiAssistant();
    AiAssistantLocator.set(fake);
    await pumpChat(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.decoration!.hintMaxLines, 1);
    expect(field.maxLines, 6);
    expect(field.textInputAction, TextInputAction.newline);

    await ask(tester, '4901411018501\nの昨日の売上は？');
    expect(fake.asked.single['question'], '4901411018501\nの昨日の売上は？');
    await fake.streams.single.close();
    await tester.pumpAndSettle();
  });

  testWidgets('barcode scan page returns the first detected code once',
      (tester) async {
    String? result = 'not set';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await BarcodeScanLauncher.open(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('商品のバーコードを枠の中に写してください'), findsOneWidget);

    final state =
        tester.state<BarcodeScanPageState>(find.byType(BarcodeScanPage));
    state.simulateDetectionForTest('4901411018501');
    state.simulateDetectionForTest('4901411018501'); // 2 回目は無視
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(result, '4901411018501');
    expect(find.byType(BarcodeScanPage), findsNothing);
  });
}

/// 1x1 の PNG(写真のテスト用)。
final _tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
