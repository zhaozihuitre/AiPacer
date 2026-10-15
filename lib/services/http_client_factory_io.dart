import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 移动端:使用标准证书校验。
/// 后端是 Cloud Run 域名(Google 签发的正式证书),不需要放行自签证书。
http.Client createHttpClient() => IOClient(HttpClient());
