import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseAdminApi {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  bool get connected => url.isNotEmpty && publishableKey.isNotEmpty;
  SupabaseClient get client => Supabase.instance.client;

  Future<void> login(String email, String password) async {
    if (!connected) throw Exception('إعدادات Supabase غير موجودة في نسخة APK');
    final response = await client.auth.signInWithPassword(email: email, password: password);
    if (response.user == null) throw Exception('تعذر تسجيل الدخول');
  }

  Future<List<Map<String, dynamic>>> listTenants() async {
    final all = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += 500) {
      final page = await client.from('marshal_tenants')
          .select('customer_code,display_name,city,is_visible,is_active,is_medical')
          .order('id').range(offset, offset + 499);
      all.addAll(page.map((e) => Map<String, dynamic>.from(e)));
      if (page.length < 500) break;
    }
    return all;
  }

  Future<void> createTenant(Map<String, dynamic> data) async {
    await client.from('marshal_tenants').insert(data);
  }

  Future<void> updateTenant(String code, Map<String, dynamic> data) async {
    await client.from('marshal_tenants').update(data).eq('customer_code', code);
  }

  Future<Map<String, dynamic>> issueActivation(String customerCode) async {
    if (!connected || client.auth.currentUser == null) {
      throw Exception('يلزم تسجيل الدخول بحساب المالك');
    }
    final result = await client.rpc('marshal_owner_issue_activation',
        params: {'p_customer_code': customerCode});
    final data = Map<String, dynamic>.from(result as Map);
    final code = data['activation_code']?.toString() ?? '';
    if (code.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(code)) {
      throw Exception('استجابة رمز التفعيل غير صحيحة');
    }
    return data;
  }

  Future<void> logout() async {
    await client.auth.signOut();
  }
}
