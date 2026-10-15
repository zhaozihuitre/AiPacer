import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/ai_chat.dart';

/// 系列の色。色覚の違いがあっても区別できる 3 色を、この順で使う(順位で色を変えない)。
/// 出典:dataviz スキルの検証済みカテゴリ配色(slot 1〜3。全ペアで CVD ΔE ≥ 9)。
const aiChartSeriesColors = [
  Color(0xFF2A78D6), // 青
  Color(0xFFEB6834), // 橙
  Color(0xFF1BAF7A), // 緑青
];

const _gridColor = Color(0x1AFFFFFF);
const _axisTextStyle = TextStyle(color: AppColors.secondaryText, fontSize: 10);

/// AI の回答に付くグラフ。折れ線(推移)・縦棒(比較)・横棒(項目別)の 3 種類。
class AiChartView extends StatelessWidget {
  const AiChartView({super.key, required this.chart});

  final AiChart chart;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'グラフ:${chart.title}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chart.title,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (chart.series.length > 1) ...[
            const SizedBox(height: 6),
            _Legend(series: chart.series),
          ],
          const SizedBox(height: 10),
          switch (chart.type) {
            AiChartType.line => _LineChartBody(chart: chart),
            AiChartType.bar => _BarChartBody(chart: chart),
            AiChartType.hbar => _HorizontalBars(chart: chart),
          },
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 数値の表示
// ---------------------------------------------------------------------------

String _comma(num value) {
  final negative = value < 0;
  final digits = value.abs().round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${negative ? '-' : ''}$buf';
}

/// ツールチップ・横棒の値:正確な値を単位付きで。
String formatChartValue(double value, String unit) {
  if (unit == '%') return '${value.toStringAsFixed(1)}%';
  final isInt = value == value.roundToDouble();
  final number = isInt ? _comma(value) : value.toStringAsFixed(1);
  return '$number$unit';
}

/// 軸の目盛り:桁が大きいときは万・億でまとめる。
String formatAxisValue(double value, String unit) {
  if (unit == '%') return '${value.round()}%';
  final abs = value.abs();
  if (abs >= 100000000) return '${_trim(value / 100000000)}億';
  if (abs >= 10000) return '${_trim(value / 10000)}万';
  return _comma(value);
}

String _trim(double v) {
  final s = v.toStringAsFixed(v.abs() >= 100 ? 0 : 1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// 0 を含み、上に少し余白を取った範囲と、きりのいい目盛り間隔。
({double min, double max, double interval}) _range(
  Iterable<double> values, {
  double? reference,
}) {
  final all = [...values, if (reference != null) reference];
  var lo = math.min(0.0, all.reduce(math.min));
  var hi = math.max(0.0, all.reduce(math.max));
  if (hi == lo) hi = lo + 1;
  final interval = _niceStep((hi - lo) / 4);
  hi = (hi / interval).ceil() * interval;
  lo = (lo / interval).floor() * interval;
  return (min: lo, max: hi, interval: interval);
}

double _niceStep(double raw) {
  final exp = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final f = raw / exp;
  final nice = f <= 1 ? 1 : (f <= 2 ? 2 : (f <= 5 ? 5 : 10));
  return nice * exp;
}

Iterable<double> _numbers(AiChart chart) =>
    chart.series.expand((s) => s.values).whereType<double>();

// ---------------------------------------------------------------------------
// 凡例
// ---------------------------------------------------------------------------

class _Legend extends StatelessWidget {
  const _Legend({required this.series});

  final List<AiChartSeries> series;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (var i = 0; i < series.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: aiChartSeriesColors[i % aiChartSeriesColors.length],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 4),
              Text(series[i].name, style: _axisTextStyle),
            ],
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 共通の軸・グリッド
// ---------------------------------------------------------------------------

FlTitlesData _titles(AiChart chart, double interval, {required bool line}) {
  final n = chart.labels.length;
  // 下の目盛りは最大 6 個程度に間引く
  final every = math.max(1, (n / 6).ceil());
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 44,
        interval: interval,
        getTitlesWidget: (value, meta) => SideTitleWidget(
          meta: meta,
          child:
              Text(formatAxisValue(value, chart.unit), style: _axisTextStyle),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 22,
        interval: 1,
        getTitlesWidget: (value, meta) {
          final i = value.round();
          if (value != i.toDouble() || i < 0 || i >= n) {
            return const SizedBox.shrink();
          }
          // 折れ線は最後の点を必ず見せる(最新の日付)
          final show = i % every == 0 || (line && i == n - 1 && n > 1);
          if (!show) return const SizedBox.shrink();
          return SideTitleWidget(
            meta: meta,
            child: Text(chart.labels[i], style: _axisTextStyle),
          );
        },
      ),
    ),
  );
}

FlGridData _grid(double interval) => FlGridData(
      drawVerticalLine: false,
      horizontalInterval: interval,
      getDrawingHorizontalLine: (_) =>
          const FlLine(color: _gridColor, strokeWidth: 1),
    );

ExtraLinesData _referenceLine(AiChart chart) {
  final ref = chart.referenceValue;
  if (ref == null) return const ExtraLinesData();
  return ExtraLinesData(horizontalLines: [
    HorizontalLine(
      y: ref,
      color: AppColors.secondaryText,
      strokeWidth: 1,
      dashArray: const [4, 3],
      label: HorizontalLineLabel(
        show: chart.referenceLabel.isNotEmpty,
        alignment: Alignment.topRight,
        style: _axisTextStyle,
        labelResolver: (_) => chart.referenceLabel,
      ),
    ),
  ]);
}

// ---------------------------------------------------------------------------
// 折れ線(推移)
// ---------------------------------------------------------------------------

class _LineChartBody extends StatelessWidget {
  const _LineChartBody({required this.chart});

  final AiChart chart;

  @override
  Widget build(BuildContext context) {
    final range = _range(_numbers(chart), reference: chart.referenceValue);
    final n = chart.labels.length;
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: (n - 1).toDouble(),
          minY: range.min,
          maxY: range.max,
          gridData: _grid(range.interval),
          borderData: FlBorderData(show: false),
          titlesData: _titles(chart, range.interval, line: true),
          extraLinesData: _referenceLine(chart),
          lineBarsData: [
            for (var s = 0; s < chart.series.length; s++)
              LineChartBarData(
                spots: [
                  for (var i = 0; i < n; i++)
                    chart.series[s].values[i] == null
                        ? FlSpot.nullSpot
                        : FlSpot(i.toDouble(), chart.series[s].values[i]!),
                ],
                color: aiChartSeriesColors[s % aiChartSeriesColors.length],
                barWidth: 2,
                isStrokeCapRound: true,
                // 点が多いときは印を付けない(線が読みにくくなるため)
                dotData: FlDotData(
                  show: n <= 12,
                  getDotPainter: (spot, _, bar, __) => FlDotCirclePainter(
                    radius: 4,
                    color: bar.color ?? aiChartSeriesColors.first,
                    strokeWidth: 2,
                    strokeColor: Colors.white,
                  ),
                ),
              ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => AppColors.slate900,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  LineTooltipItem(
                    '${spot == spots.first ? '${chart.labels[spot.x.round()]}\n' : ''}'
                    '${chart.series[spot.barIndex].name}:'
                    '${formatChartValue(spot.y, chart.unit)}',
                    const TextStyle(color: Colors.white, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 縦棒(比較)
// ---------------------------------------------------------------------------

class _BarChartBody extends StatelessWidget {
  const _BarChartBody({required this.chart});

  final AiChart chart;

  @override
  Widget build(BuildContext context) {
    final range = _range(_numbers(chart), reference: chart.referenceValue);
    final n = chart.labels.length;
    final seriesCount = chart.series.length;
    // 項目数・系列数に合わせて棒を細くする(最大 18px)
    final width = math.min(18.0, 220 / (n * seriesCount));
    return SizedBox(
      height: 180,
      child: BarChart(
        BarChartData(
          minY: range.min,
          maxY: range.max,
          gridData: _grid(range.interval),
          borderData: FlBorderData(show: false),
          titlesData: _titles(chart, range.interval, line: false),
          extraLinesData: _referenceLine(chart),
          alignment: BarChartAlignment.spaceAround,
          barGroups: [
            for (var i = 0; i < n; i++)
              BarChartGroupData(
                x: i,
                barsSpace: 2,
                barRods: [
                  for (var s = 0; s < seriesCount; s++)
                    BarChartRodData(
                      toY: chart.series[s].values[i] ?? 0,
                      width: width,
                      color: chart.series[s].values[i] == null
                          ? Colors.transparent
                          : aiChartSeriesColors[s % aiChartSeriesColors.length],
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                    ),
                ],
              ),
          ],
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => AppColors.slate900,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final v = chart.series[rodIndex].values[groupIndex];
                if (v == null) return null;
                final name =
                    seriesCount > 1 ? '${chart.series[rodIndex].name}:' : '';
                return BarTooltipItem(
                  '${chart.labels[groupIndex]}\n$name${formatChartValue(v, chart.unit)}',
                  const TextStyle(color: Colors.white, fontSize: 11),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 横棒(項目別)
// ---------------------------------------------------------------------------

/// 項目名が長い日本語でも読めるよう、1 行ずつ「名前・棒・値」を並べる。
/// 系列が 1 つで基準線があるとき(予算達成率など)は、基準以上を緑・未満を橙にする
/// (既存の「カテゴリ別売上推移」と同じ色分け。値の数字を必ず添える)。
class _HorizontalBars extends StatelessWidget {
  const _HorizontalBars({required this.chart});

  final AiChart chart;

  @override
  Widget build(BuildContext context) {
    final values = _numbers(chart).toList();
    final ref = chart.referenceValue;
    final maxValue = [...values, if (ref != null) ref].fold<double>(
      0,
      (m, v) => math.max(m, v),
    );
    final scale = maxValue <= 0 ? 1.0 : maxValue;
    final status = chart.series.length == 1 && ref != null;
    return Column(
      children: [
        for (var i = 0; i < chart.labels.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(
                    chart.labels[i],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 11,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      for (var s = 0; s < chart.series.length; s++)
                        Padding(
                          padding: EdgeInsets.only(top: s == 0 ? 0 : 2),
                          child: _HBarRow(
                            value: chart.series[s].values[i],
                            scale: scale,
                            reference: ref,
                            unit: chart.unit,
                            color: status
                                ? ((chart.series[s].values[i] ?? 0) >= ref
                                    ? AppColors.success
                                    : AppColors.warning)
                                : aiChartSeriesColors[
                                    s % aiChartSeriesColors.length],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (ref != null && chart.referenceLabel.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '┆ ${chart.referenceLabel}(${formatChartValue(ref, chart.unit)})',
              style: _axisTextStyle,
            ),
          ),
      ],
    );
  }
}

class _HBarRow extends StatelessWidget {
  const _HBarRow({
    required this.value,
    required this.scale,
    required this.reference,
    required this.unit,
    required this.color,
  });

  final double? value;
  final double scale;
  final double? reference;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final ref = reference;
              return SizedBox(
                height: 10,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.statusChipBgNeutral,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    if (v != null && v > 0)
                      Container(
                        width: w * (v / scale).clamp(0.0, 1.0),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    if (ref != null && ref > 0)
                      Positioned(
                        left: w * (ref / scale).clamp(0.0, 1.0) - 1,
                        top: -2,
                        bottom: -2,
                        child: Container(width: 2, color: AppColors.text),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 76,
          child: Text(
            v == null ? '-' : formatChartValue(v, unit),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
