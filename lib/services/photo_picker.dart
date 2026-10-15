import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// 写真の取り方。
enum PhotoSource { camera, gallery }

/// AI に送る写真を撮る / 選ぶ。テストでは [pick] を差し替える。
///
/// Claude が読みやすく、通信量も小さくなるよう、長辺 1568px・JPEG 品質 80 に縮めて返す(通常は数百 KB)。
class PhotoPickerLauncher {
  static Future<Uint8List?> Function(PhotoSource source) pick = _defaultPick;

  static void reset() => pick = _defaultPick;

  static Future<Uint8List?> _defaultPick(PhotoSource source) async {
    final file = await ImagePicker().pickImage(
      source: source == PhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 1568,
      maxHeight: 1568,
      imageQuality: 80,
    );
    return file?.readAsBytes();
  }
}
