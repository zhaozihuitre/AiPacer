# AI PACER

PACER アプリの「AI アソシエイト」だけを取り出した Flutter アプリ(Android / Web)。
ログイン後すぐに AI との会話画面になり、売上・予算・在庫・棚割・顧客・商圏のデータについて質問できる。

元のアプリ(retail-ai-inc/mdlink-mobile-app)から、店舗巡回・商品スキャン・商品詳細・企業選択・店舗選択を外した。

## 画面

| 画面 | 内容 |
|---|---|
| ログイン | メール + パスワード、Microsoft / Google(WorkOS、Go バックエンド経由)。ログイン状態は端末に保存 |
| AI 会話 | 回答のストリーミング表示、データ取得中の表示、グラフ(折れ線・縦棒・横棒)、続けて聞く候補、会話履歴(再表示・削除)、新しい会話、音声入力、自動読み上げ、写真(最大 3 枚)、バーコードスキャン(JAN を入力欄へ) |

- **企業・店舗は選ばない**。agent には `companyCode` / `storeCode` を送らないので、店舗は質問の中で指定する(例:「67番店舗の昨日の売上」)
- デザインはダーク + ネオン(シアン → バイオレット)。トークンは `lib/app_theme.dart`、共通部品(オーロラ背景・ガラスの面・AI の光球・ネオンボタンなど)は `lib/widgets/tech_ui.dart`

## 接続先

| 用途 | 既定 | 変更 |
|---|---|---|
| 認証(Go バックエンド) | `https://mdlink-app-backend-cjy6246wiq-an.a.run.app/api/v1` | `--dart-define=API_BASE_URL=...` |
| AI(mdlink-mobile-app-agent) | `https://mdlink-mobile-app-agent-cjy6246wiq-an.a.run.app/api/v1/ai` | `--dart-define=AI_AGENT_BASE_URL=...`(`mock` でデモデータ) |

バックエンドと agent は PACER と共用(このリポジトリには含まない)。会話履歴も PACER と同じ利用者単位で共有される。

## 開発

```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter pub get
flutter analyze lib test
flutter test
JAVA_HOME=~/.jdks/jdk-21.0.12.1+1 flutter build apk --release --split-per-abi
```

- テストは `test/widget_test.dart`。繰り返しアニメーションは `TechMotion.enabled = false` で止めている(止めないと `pumpAndSettle` が終わらない)
- Android の applicationId は `com.retailai.aipacer`(PACER と同じ端末に入れられる)
- OAuth のコールバックは PACER と同じ `com.retailai.mdlink://auth/callback`(WorkOS に登録済みの Redirect URI)。PACER も入っている端末では、Microsoft / Google ログインの戻り先でアプリの選択が出ることがある

## リリース

`main` への push で GitHub Actions が APK をビルドする。`v*` タグを push すると GitHub Release(分割 APK + QR コード)を作る。
