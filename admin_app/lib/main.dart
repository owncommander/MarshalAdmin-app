import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_admin_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  if (url.isNotEmpty && key.isNotEmpty) {
    await Supabase.initialize(url: url, anonKey: key);
  }
  runApp(const MarshalAdmin());
}

class Customer {
  final String code;
  String name;
  bool medical, visible, active;
  Customer({required this.code, required this.name, required this.medical, this.visible = false, this.active = false});
  factory Customer.fromMap(Map<String, dynamic> m) => Customer(
    code: '${m['customer_code']}', name: '${m['display_name']}', medical: m['is_medical'] == true,
    visible: m['is_visible'] == true, active: m['is_active'] == true);
  Map<String, dynamic> toMap() => {'code': code, 'name': name, 'medical': medical, 'visible': visible, 'active': active};
}

class MarshalAdmin extends StatelessWidget {
  const MarshalAdmin({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false, title: 'MarPatients Admin',
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: const Color(0xfff7f7f5),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffd66b24)),
      fontFamily: 'Roboto', appBarTheme: const AppBarTheme(backgroundColor: Color(0xfff7f7f5))),
    home: const AdminHome());
}

class AdminHome extends StatefulWidget { const AdminHome({super.key}); @override State<AdminHome> createState() => _AdminHomeState(); }
class _AdminHomeState extends State<AdminHome> {
  static const secure = FlutterSecureStorage();
  final pin = TextEditingController();
  final ownerUsername = TextEditingController();
  final api = SupabaseAdminApi();
  bool get remoteMode => api.connected;
  final search = TextEditingController();
  List<Customer> customers = [];
  bool ready = false, unlocked = false, creatingPin = false, busy = false;
  String filter = 'all';
  @override void initState() { super.initState(); _load(); }
  @override void dispose() { pin.dispose(); ownerUsername.dispose(); search.dispose(); super.dispose(); }

  Future<void> _load() async {
    if (remoteMode) {
      if (mounted) setState(() { creatingPin = false; ready = true; });
      return;
    }
    final storedPin = await secure.read(key: 'owner_pin');
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('customers_v1');
    final raw = saved ?? await rootBundle.loadString('assets/complexes.json');
    final parsed = (jsonDecode(raw) as List).map((e) => Customer.fromMap(Map<String, dynamic>.from(e as Map))).toList();
    if (!mounted) return;
    setState(() { customers = parsed; creatingPin = storedPin == null; ready = true; });
  }
  Future<void> _unlock() async {
    if (busy) return;
    final value = pin.text.trim();
    if (remoteMode) {
      if (value.isEmpty || ownerUsername.text.trim().isEmpty) { _message('أدخل اسم المستخدم وكلمة المرور'); return; }
      setState(() => busy = true);
      try {
        await api.login(ownerUsername.text.trim(), value);
        final rows = await api.listTenants();
        if (mounted) setState(() { customers = rows.map(Customer.fromMap).toList(); unlocked = true; });
        pin.clear();
      } catch (e) { if (mounted) _message(e.toString().replaceFirst('Exception: ', '')); }
      finally { if (mounted) setState(() => busy = false); }
      return;
    }
    if (value.length < 8) { _message('كلمة المرور لازم تكون 8 أحرف على الأقل'); return; }
    setState(() => busy = true);
    try {
      if (creatingPin) { await secure.write(key: 'owner_pin', value: value); setState(() { creatingPin = false; unlocked = true; }); }
      else { final saved = await secure.read(key: 'owner_pin'); if (saved == value) { setState(() => unlocked = true); } else { _message('كلمة المرور غير صحيحة'); } }
      pin.clear();
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> _issueActivation(Customer c) async {
    if (!remoteMode || !c.medical || !c.active || busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إصدار رمز تفعيل السيرفر'),
        content: Text('إصدار رمز جديد للمجمع: ${c.name} (كود ${c.code})؟\n'
            'الرمز صالح لمدة 30 دقيقة ويُستخدم مرة واحدة فقط.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إصدار')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      final data = await api.issueActivation(c.code);
      if (!mounted) return;
      final activationCode = data['activation_code'].toString();
      final expiry = data['expires_at']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('رمز التفعيل — يُعرض مرة واحدة'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c.name} — ${c.code}'),
            const SizedBox(height: 12),
            SelectableText(activationCode, textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            const SizedBox(height: 10),
            Text('ينتهي: $expiry', style: const TextStyle(fontSize: 12)),
            const Text('لا تشارك الرمز إلا مع المسؤول عن سيرفر هذا المجمع.',
                style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: activationCode));
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('تم نسخ الرمز')));
              },
              icon: const Icon(Icons.copy), label: const Text('نسخ الرمز'),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx),
                child: const Text('إغلاق')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _message('تعذر إصدار الرمز: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> _refreshRemote() async {
    if (!remoteMode) return;
    final rows = await api.listTenants();
    if (mounted) setState(() => customers = rows.map(Customer.fromMap).toList());
  }
  Future<void> _setFlag(Customer c, {bool? visible, bool? active}) async {
    if (remoteMode) {
      try {
        await api.updateTenant(c.code, {if (visible != null) 'is_visible': visible, if (active != null) 'is_active': active});
        await _refreshRemote();
        if (mounted) _message('تم حفظ التغيير على السيرفر');
      } catch (e) { if (mounted) _message(e.toString().replaceFirst('Exception: ', '')); }
    } else {
      setState(() { if (visible != null) c.visible = visible; if (active != null) c.active = active; });
      await _save();
    }
  }
  Future<void> _save() async {
    if (remoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('customers_v1', jsonEncode(customers.map((e) => e.toMap()).toList()));
  }
  void _message(String msg) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg))); }
  Future<void> _edit({Customer? item}) async {
    final code = TextEditingController(text: item?.code ?? '');
    final name = TextEditingController(text: item?.name ?? '');
    bool medical = item?.medical ?? true;
    final result = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
      title: Text(item == null ? 'إضافة عميل' : 'تعديل العميل'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: code, enabled: item == null, decoration: const InputDecoration(labelText: 'كود عميل Marshal')),
        const SizedBox(height: 12), TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')),
        SwitchListTile(title: const Text('منشأة طبية'), value: medical, onChanged: (v) => update(() => medical = v)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ'))],
    )));
    if (result != true) { code.dispose(); name.dispose(); return; }
    final c = code.text.trim(), n = name.text.trim();
    code.dispose(); name.dispose();
    if (c.isEmpty || n.isEmpty) { _message('أدخل الكود والاسم'); return; }
    if (item == null && customers.any((e) => e.code == c)) { _message('كود العميل موجود بالفعل'); return; }
    if (remoteMode) {
      try {
        if (item == null) {
          await api.createTenant({'customer_code': c, 'display_name': n, 'is_medical': medical, 'is_visible': false, 'is_active': false});
        } else {
          await api.updateTenant(c, {'display_name': n, 'is_medical': medical});
        }
        await _refreshRemote();
        if (mounted) _message('تم حفظ العميل على السيرفر');
      } catch (e) { if (mounted) _message(e.toString().replaceFirst('Exception: ', '')); }
      return;
    }
    setState(() { if (item == null) { customers.add(Customer(code: c, name: n, medical: medical)); } else { item.name = n; item.medical = medical; } });
    await _save();
    _message('تم الحفظ على هذا الهاتف فقط');
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: !ready
    ? const Scaffold(body: Center(child: CircularProgressIndicator()))
    : !unlocked ? _login() : _dashboard());
  Widget _login() => Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(child: Padding(
    padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 430), child: Card(
      child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Image.asset('assets/marshal_logo.jpg', height: 86), const SizedBox(height: 12),
        const Text('MarPatients Admin', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8), Text(remoteMode ? 'حساب المالك — التحقق عبر السيرفر' : (creatingPin ? 'إنشاء كلمة مرور المالك لأول مرة' : 'دخول المالك فقط'), style: const TextStyle(color: Colors.black54)),
        if (remoteMode) ...[const SizedBox(height: 18), TextField(controller: ownerUsername, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'البريد الإلكتروني للمالك'))],
        const SizedBox(height: 20), TextField(controller: pin, obscureText: true, textInputAction: TextInputAction.done,
          onSubmitted: (_) => _unlock(), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'كلمة مرور الإدارة')),
        const SizedBox(height: 14), SizedBox(width: double.infinity, child: FilledButton(onPressed: busy ? null : _unlock,
          child: Text(!remoteMode && creatingPin ? 'إنشاء كلمة مرور محلية' : 'دخول'))),
        const SizedBox(height: 12), Text(remoteMode ? 'اتصال آمن بخدمة المجمعات. الحساب يُتحقق منه على السيرفر.' : 'نسخة تجريبية محلية. لا توجد مزامنة مع هواتف المرضى.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ])),
    )))))));
  Widget _dashboard() {
    final q = search.text.trim().toLowerCase();
    final rows = customers.where((c) => (filter == 'all' || (filter == 'medical' && c.medical) || (filter == 'visible' && c.visible)) &&
      (q.isEmpty || c.name.toLowerCase().contains(q) || c.code.contains(q))).toList();
    return Scaffold(appBar: AppBar(title: const Text('إدارة مجمعات Marshal', style: TextStyle(fontWeight: FontWeight.bold)), actions: [
      if (remoteMode) IconButton(tooltip: 'تحديث القائمة', onPressed: () async { try { await _refreshRemote(); } catch (e) { if (mounted) _message(e.toString()); } }, icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'قفل', onPressed: () { api.logout(); setState(() => unlocked = false); }, icon: const Icon(Icons.lock_outline))]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('عميل جديد')),
      body: Column(children: [
        Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 8, 16, 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('لوحة المالك', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5), Text(remoteMode ? 'البيانات متصلة بالسيرفر. يظهر للمريض المجمع الطبي الظاهر والمفعّل فقط.' : 'التغييرات محفوظة على هذا الهاتف فقط، وليست منشورة للمرضى.', style: const TextStyle(color: Colors.deepOrange, fontSize: 12)),
          const SizedBox(height: 14), Row(children: [
            _metric('العملاء', customers.length), const SizedBox(width: 8),
            _metric('طبي', customers.where((c) => c.medical).length), const SizedBox(width: 8),
            _metric('ظاهر', customers.where((c) => c.visible).length),
          ]), const SizedBox(height: 14),
          TextField(controller: search, onChanged: (_) => setState(() {}), decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search), hintText: 'ابحث باسم العميل أو الكود', filled: true, fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
          const SizedBox(height: 10), SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')),
            const SizedBox(width: 8), ChoiceChip(label: const Text('المنشآت الطبية'), selected: filter == 'medical', onSelected: (_) => setState(() => filter = 'medical')),
            const SizedBox(width: 8), ChoiceChip(label: const Text('الظاهرة'), selected: filter == 'visible', onSelected: (_) => setState(() => filter = 'visible')),
          ])),
        ])),
        Expanded(child: ListView.builder(padding: const EdgeInsets.fromLTRB(12, 0, 12, 90), itemCount: rows.length, itemBuilder: (ctx, index) {
          final c = rows[index];
          return Card(margin: const EdgeInsets.only(bottom: 9), child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
            Row(children: [CircleAvatar(backgroundColor: const Color(0xffffefe2), child: Icon(c.medical ? Icons.local_hospital_outlined : Icons.storefront_outlined, color: const Color(0xffb95d1d))),
              const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                Text('كود داخلي: ${c.code}', style: const TextStyle(fontSize: 11, color: Colors.black45))])),
              IconButton(tooltip: 'تعديل', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(item: c))]),
            if (remoteMode && c.medical && c.active) ...[
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight, child: OutlinedButton.icon(
                onPressed: busy ? null : () => _issueActivation(c),
                icon: const Icon(Icons.vpn_key_outlined),
                label: const Text('إصدار رمز تفعيل السيرفر'),
              )),
            ],
            const Divider(height: 18), Row(children: [
              Expanded(child: Row(children: [const Text('إظهار'), Switch(value: c.visible, onChanged: (v) => _setFlag(c, visible: v))])),
              Expanded(child: Row(children: [const Text('تفعيل'), Switch(value: c.active, onChanged: (v) => _setFlag(c, active: v))])),
            ]),
          ])));
        }))
      ]));
  }
  Widget _metric(String label, int value) => Expanded(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(
    color: Colors.white, borderRadius: BorderRadius.circular(14)), child: Column(children: [
    Text('$value', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 21)),
    Text(label, style: const TextStyle(color: Colors.black54, fontSize: 12))])));
}
