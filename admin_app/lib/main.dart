import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const MarshalAdmin()); }

class Customer {
  final String code;
  String name;
  bool medical, visible, active;
  Customer({required this.code, required this.name, required this.medical, this.visible = false, this.active = false});
  factory Customer.fromMap(Map<String, dynamic> m) => Customer(
    code: '${m['code']}', name: '${m['name']}', medical: m['medical'] == true,
    visible: m['visible'] == true, active: m['active'] == true);
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
  final search = TextEditingController();
  List<Customer> customers = [];
  bool ready = false, unlocked = false, creatingPin = false, busy = false;
  String filter = 'all';
  @override void initState() { super.initState(); _load(); }
  @override void dispose() { pin.dispose(); search.dispose(); super.dispose(); }

  Future<void> _load() async {
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
    if (value.length < 8) { _message('كلمة المرور لازم تكون 8 أحرف على الأقل'); return; }
    setState(() => busy = true);
    try {
      if (creatingPin) { await secure.write(key: 'owner_pin', value: value); setState(() { creatingPin = false; unlocked = true; }); }
      else { final saved = await secure.read(key: 'owner_pin'); if (saved == value) { setState(() => unlocked = true); } else { _message('كلمة المرور غير صحيحة'); } }
      pin.clear();
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> _save() async {
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
        TextField(controller: code, enabled: item == null, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'كود عميل Marshal')),
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
        const SizedBox(height: 8), Text(creatingPin ? 'إنشاء كلمة مرور المالك لأول مرة' : 'دخول المالك فقط', style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 20), TextField(controller: pin, obscureText: true, textInputAction: TextInputAction.done,
          onSubmitted: (_) => _unlock(), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'كلمة مرور الإدارة')),
        const SizedBox(height: 14), SizedBox(width: double.infinity, child: FilledButton(onPressed: busy ? null : _unlock,
          child: Text(creatingPin ? 'إنشاء حساب المالك' : 'دخول'))),
        const SizedBox(height: 12), const Text('نسخة تجريبية محلية. لا توجد مزامنة مع هواتف المرضى.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54)),
      ])),
    )))))));
  Widget _dashboard() {
    final q = search.text.trim().toLowerCase();
    final rows = customers.where((c) => (filter == 'all' || (filter == 'medical' && c.medical) || (filter == 'visible' && c.visible)) &&
      (q.isEmpty || c.name.toLowerCase().contains(q) || c.code.contains(q))).toList();
    return Scaffold(appBar: AppBar(title: const Text('إدارة مجمعات Marshal', style: TextStyle(fontWeight: FontWeight.bold)), actions: [
      IconButton(tooltip: 'قفل', onPressed: () => setState(() => unlocked = false), icon: const Icon(Icons.lock_outline))]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('عميل جديد')),
      body: Column(children: [
        Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 8, 16, 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('لوحة المالك', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5), const Text('التغييرات محفوظة على هذا الهاتف فقط، وليست منشورة للمرضى.', style: TextStyle(color: Colors.deepOrange, fontSize: 12)),
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
            const Divider(height: 18), Row(children: [
              Expanded(child: Row(children: [const Text('إظهار'), Switch(value: c.visible, onChanged: (v) async { setState(() => c.visible = v); await _save(); })])),
              Expanded(child: Row(children: [const Text('تفعيل'), Switch(value: c.active, onChanged: (v) async { setState(() => c.active = v); await _save(); })])),
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
