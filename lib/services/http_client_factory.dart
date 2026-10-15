import 'package:http/http.dart' as http;

/// Web 默认实现:浏览器自身就是个 http client,证书校验交给浏览器。
http.Client createHttpClient() => http.Client();
