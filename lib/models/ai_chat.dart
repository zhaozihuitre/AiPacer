// AI アソシエイト画面(`design/8.AIChat`)的数据模型。

enum AiTrend { up, down, flat }

/// 指标卡(本日累計売上 / 来客数 / 客単価)。
class AiMetric {
  const AiMetric({
    required this.label,
    required this.value,
    this.unit,
    required this.delta,
    required this.note,
    this.trend = AiTrend.up,
    this.highlightNote = false,
  });

  final String label;
  final String value;
  final String? unit;
  final String delta;
  final String note;
  final AiTrend trend;

  /// note 是否用强调色(例如「予算比 好調」)。
  final bool highlightNote;
}

/// カテゴリ別売上。`progress` 是目标进捗率(1.10 = 110%)。
class AiCategorySales {
  const AiCategorySales({
    required this.name,
    required this.amount,
    required this.progress,
  });

  final String name;
  final int amount;
  final double progress;
}

class AiInsight {
  const AiInsight({
    required this.title,
    required this.body,
    required this.tag,
    this.actionLabel,
  });

  final String title;
  final String body;
  final String tag;
  final String? actionLabel;
}

/// AI 的一次回答。metrics / categories / insight 为空时只显示文本。
class AiReply {
  const AiReply({
    required this.text,
    required this.answeredAt,
    this.tag,
    this.aggregatedAt,
    this.metrics = const [],
    this.categories = const [],
    this.insight,
    this.followUps = const [],
    this.isDemo = false,
  });

  final String text;
  final DateTime answeredAt;
  final String? tag;
  final DateTime? aggregatedAt;
  final List<AiMetric> metrics;
  final List<AiCategorySales> categories;
  final AiInsight? insight;
  final List<String> followUps;

  /// mock adapter 返回的演示数据,画面上会标「デモデータ」。
  final bool isDemo;
}

/// 回答の進み具合。[AiAssistant.ask] がこの順で流す:
/// [AiStarted] → [AiTextDelta] / [AiToolProgress](繰り返し)→ [AiFinished] または [AiFailed]
sealed class AiEvent {
  const AiEvent();

  /// mdlink-mobile-app-agent の SSE イベント(JSON)を変換する。知らない type は null。
  static AiEvent? fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      'start' => AiStarted(json['conversationId'] as String),
      'text' => AiTextDelta(json['text'] as String? ?? ''),
      'tool' => AiToolProgress(
          json['name'] as String? ?? '',
          json['status'] as String? ?? '',
        ),
      'chart' => AiChartReceived(
          AiChart.fromJson(json['chart'] as Map<String, dynamic>),
        ),
      'suggestions' => AiSuggestionsReceived([
          for (final q in json['questions'] as List<dynamic>? ?? const []) '$q',
        ]),
      'done' => const AiFinished(),
      'error' => AiFailed(json['message'] as String? ?? ''),
      _ => null,
    };
  }
}

/// 会話が決まった(新規作成または継続)。
class AiStarted extends AiEvent {
  const AiStarted(this.conversationId);
  final String conversationId;
}

/// 回答テキストの続き。
class AiTextDelta extends AiEvent {
  const AiTextDelta(this.text);
  final String text;
}

/// データ取得ツールの状態。status は running / done / error。
class AiToolProgress extends AiEvent {
  const AiToolProgress(this.name, this.status);
  final String name;
  final String status;
}

/// 回答に付けるグラフが届いた。
class AiChartReceived extends AiEvent {
  const AiChartReceived(this.chart);
  final AiChart chart;
}

/// 「続けて聞く」質問候補が届いた。後から届いたもので置き換える。
class AiSuggestionsReceived extends AiEvent {
  const AiSuggestionsReceived(this.questions);
  final List<String> questions;
}

/// 回答完了。[reply] があればそれを表示する(デモ用の構造化データ)。
/// 無ければそれまでの [AiTextDelta] をつないだものが回答。
class AiFinished extends AiEvent {
  const AiFinished({this.reply});
  final AiReply? reply;
}

/// サーバー側で回答できなかった。[message] は利用者向けの文言。
class AiFailed extends AiEvent {
  const AiFailed(this.message);
  final String message;
}

/// 会話履歴の一覧の 1 行。
class AiConversationSummary {
  const AiConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.storeCode = '',
  });

  factory AiConversationSummary.fromJson(Map<String, dynamic> json) {
    return AiConversationSummary(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      storeCode: json['storeCode'] as String? ?? '',
      updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
    );
  }

  final String id;
  final String title;
  final String storeCode;
  final DateTime updatedAt;
}

/// 履歴から読み込んだメッセージ(画面表示用のテキストのみ)。
class AiHistoryMessage {
  const AiHistoryMessage({
    required this.isUser,
    required this.text,
    required this.createdAt,
    this.charts = const [],
    this.suggestions = const [],
    this.imageIds = const [],
  });

  factory AiHistoryMessage.fromJson(Map<String, dynamic> json) {
    return AiHistoryMessage(
      isUser: json['role'] == 'user',
      text: json['text'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
      charts: [
        for (final c in json['charts'] as List<dynamic>? ?? const [])
          AiChart.fromJson(c as Map<String, dynamic>),
      ],
      suggestions: [
        for (final q in json['suggestions'] as List<dynamic>? ?? const []) '$q',
      ],
      imageIds: [
        for (final id in json['images'] as List<dynamic>? ?? const []) '$id',
      ],
    );
  }

  final bool isUser;
  final String text;
  final DateTime createdAt;

  /// 回答に付いていたグラフ。
  final List<AiChart> charts;

  /// 回答に付いていた「続けて聞く」質問候補。
  final List<String> suggestions;

  /// 質問に付けた写真の id([AiAssistant.loadImage] で取得する)。
  final List<String> imageIds;
}

/// グラフの種類。line = 推移、bar = 比較(縦棒)、hbar = 項目別(横棒)。
enum AiChartType { line, bar, hbar }

class AiChartSeries {
  const AiChartSeries({required this.name, required this.values});

  final String name;

  /// [AiChart.labels] と同じ数・同じ順。データが無い点は null。
  final List<double?> values;
}

/// AI の回答に付くグラフのデータ(mdlink-mobile-app-agent の show_chart)。描画はアプリ側で行う。
class AiChart {
  const AiChart({
    required this.type,
    required this.title,
    required this.labels,
    required this.series,
    this.unit = '',
    this.referenceValue,
    this.referenceLabel = '',
  });

  factory AiChart.fromJson(Map<String, dynamic> json) {
    final ref = json['reference'] as Map<String, dynamic>?;
    return AiChart(
      type: AiChartType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => AiChartType.bar,
      ),
      title: json['title'] as String? ?? '',
      unit: json['unit'] as String? ?? '',
      labels: [for (final l in json['labels'] as List<dynamic>) '$l'],
      series: [
        for (final s in json['series'] as List<dynamic>)
          AiChartSeries(
            name: (s as Map<String, dynamic>)['name'] as String? ?? '',
            values: [
              for (final v in s['values'] as List<dynamic>)
                (v as num?)?.toDouble(),
            ],
          ),
      ],
      referenceValue: (ref?['value'] as num?)?.toDouble(),
      referenceLabel: ref?['label'] as String? ?? '',
    );
  }

  final AiChartType type;
  final String title;

  /// 円 / % / 個 / 人 / 空。
  final String unit;
  final List<String> labels;
  final List<AiChartSeries> series;

  /// 基準線(例:予算達成率 100%)。
  final double? referenceValue;
  final String referenceLabel;
}
