import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_theme.dart';

/// バーコードを 1 つ読み取って返すだけの全画面スキャナー(AI タブの「+」→「バーコードをスキャン」)。
///
/// 商品タブのスキャン画面と違い、商品情報の取得はしない。最初に読めたコードで
/// カメラを止めて `Navigator.pop(code)` する。閉じたときは null。
class BarcodeScanPage extends StatefulWidget {
  const BarcodeScanPage({super.key});

  @override
  State<BarcodeScanPage> createState() => BarcodeScanPageState();
}

class BarcodeScanPageState extends State<BarcodeScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.qrCode,
    ],
  );
  bool _done = false;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        _finish(value);
        return;
      }
    }
  }

  /// テスト用:カメラを使わずに読み取りを再現する。
  @visibleForTesting
  void simulateDetectionForTest(String code) => _finish(code);

  void _finish(String code) {
    // 同じコードを続けて検出しても 1 回だけ返す
    if (_done || !mounted) return;
    _done = true;
    _controller.stop();
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScanError(error: error),
          ),
          const _ScanFrame(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '閉じる',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: _torchOn ? 'ライトを消す' : 'ライトをつける',
                    onPressed: () async {
                      await _controller.toggleTorch();
                      if (mounted) setState(() => _torchOn = !_torchOn);
                    },
                    icon: Icon(
                      _torchOn ? Icons.flash_on : Icons.flash_off,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 72,
            child: Text(
              '商品のバーコードを枠の中に写してください',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// 読み取り位置の目安になる枠。
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 260,
        height: 160,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 2),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),
    );
  }
}

class _ScanError extends StatelessWidget {
  const _ScanError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final permission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          permission
              ? 'カメラの権限がありません。端末の設定で PACER のカメラを許可してください'
              : 'カメラを起動できませんでした(${error.errorCode.name})',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }
}

/// AI タブからスキャナーを開く処理。テストではフェイクに差し替える。
class BarcodeScanLauncher {
  static Future<String?> Function(BuildContext context) open = _openPage;

  static Future<String?> _openPage(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const BarcodeScanPage(),
      ),
    );
  }

  static void reset() => open = _openPage;
}
