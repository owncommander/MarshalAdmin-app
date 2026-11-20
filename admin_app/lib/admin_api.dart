import 'dart:convert';
import 'package:http/http.dart' as http;

/// Public API URL is not a secret. No admin credentials are compiled into the APK.
const marshalApiUrl = String.fromEnvironment('MAR_API_URL', defaultValue: '');

class AdminApi {
  String? _token;
  bool get connected => marshalApiUrl.trim().isNotEmpty;
  Uri _uri(String path) {
    final base = Uri.tryParse(marshalApiUrl.trim());
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw Exception('عنوان السيرفر غير صحيح: يجب أن يبدأ بـ https://');
    }
    return base.replace(path: '${base.path.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, dynamic>? body, bool authenticated = true}) async {
    final headers = <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json'};
    if (authenticated) {
      if (_token == null) throw Exception('انتهت جلسة المدير، سجّل الدخول مرة أخرى');
      headers['Authorization'] = 'Bearer $_token';
    }
    final uri = _uri(path);
    late final http.Response res;
    try {
      switch (method) {
        case 'POST':
          res = await http.post(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 15));
          break;
        case 'PATCH':
          res = await http.patch(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 15));
          break;
        default:
          res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
      }
    } catch (_) {
      throw Exception('تعذّر الاتصال بالسيرفر. تأكد من الإنترنت وحالة الخدمة');
    }
    if (res.statusCode == 401) { _token = null; throw Exception('بيانات الدخول غير صحيحة أو انتهت الجلسة'); }
    if (res.statusCode == 429) throw Exception('محاولات كثيرة، حاول بعد قليل');
    if (res.statusCode == 409) throw Exception('كود العميل موجود بالفعل');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('فشل الطلب (HTTP ${res.statusCode})');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)) as Map);
  }

  Future<void> login(String username, String password) async {
    final result = await _request('POST', '/v1/admin/login',
        body: {'username': username, 'password': password}, authenticated: false);
    _token = result['access_token'] as String;
  }

  void logout() => _token = null;

  Future<List<Map<String, dynamic>>> listTenants() async {
    final result = await _request('GET', '/v1/admin/tenants');
    return (result['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> createTenant(Map<String, dynamic> customer) async {
    await _request('POST', '/v1/admin/tenants', body: customer);
  }

  Future<void> updateTenant(String code, Map<String, dynamic> changes) async {
    await _request('PATCH', '/v1/admin/tenants/${Uri.encodeComponent(code)}', body: changes);
  }
}
