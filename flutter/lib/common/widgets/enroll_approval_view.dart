// ---------------------------------------------------------------------------
// 控制端「入网审批」页（三端架构：服务端 / 客户端 / 控制端）
// ---------------------------------------------------------------------------
// 对接 hbbs 入网审批网关（Enrollment Gate）的 HTTP 接口：
//   GET  <admin-url>/enroll/api/list     ?token=xxx
//   POST <admin-url>/enroll/api/approve  ?token=xxx&id=xxx
//   POST <admin-url>/enroll/api/reject   ?token=xxx&id=xxx
//   POST <admin-url>/enroll/api/delete   ?token=xxx&id=xxx
//
// 服务器地址与 Token 保存在本机 Flutter 本地选项里：
//   enroll-admin-url / enroll-admin-token
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;

const String kEnrollAdminUrl = 'enroll-admin-url';
const String kEnrollAdminToken = 'enroll-admin-token';

class EnrollApprovalView extends StatefulWidget {
  const EnrollApprovalView({Key? key}) : super(key: key);

  @override
  State<EnrollApprovalView> createState() => _EnrollApprovalViewState();
}

class _Entry {
  final String id;
  final String status;
  final String ip;
  final int firstSeen;
  final int lastSeen;
  final int hits;
  _Entry(this.id, this.status, this.ip, this.firstSeen, this.lastSeen, this.hits);
}

class _EnrollApprovalViewState extends State<EnrollApprovalView> {
  Timer? _timer;
  bool _busy = false;
  String _err = '';
  List<_Entry> _items = [];
  int _lastPending = -1;
  bool _cfgOpen = false;

  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = bind.getLocalFlutterOption(k: kEnrollAdminUrl);
    _tokenCtrl.text = bind.getLocalFlutterOption(k: kEnrollAdminToken);
    _refresh();
    _timer = Timer.periodic(
        const Duration(seconds: 3), (t) => _refresh(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _baseUrl() {
    var u = bind.getLocalFlutterOption(k: kEnrollAdminUrl).trim();
    if (u.isNotEmpty && u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  Future<void> _refresh({bool quiet = false}) async {
    final url = _baseUrl();
    final token = bind.getLocalFlutterOption(k: kEnrollAdminToken).trim();
    if (url.isEmpty || token.isEmpty) {
      if (!quiet) setState(() => _err = '尚未配置审批服务器地址或 Token');
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      final res = await http
          .get(Uri.parse('$url/enroll/api/list?token=${Uri.encodeQueryComponent(token)}'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 401) {
        setState(() => _err = 'Token 不正确');
        return;
      }
      if (res.statusCode != 200) {
        setState(() => _err = '服务端返回 ${res.statusCode}');
        return;
      }
      final list = (jsonDecode(utf8.decode(res.bodyBytes)) as List)
          .map((e) => _Entry(
                (e['id'] ?? '').toString(),
                (e['status'] ?? '').toString(),
                (e['ip'] ?? '').toString(),
                (e['first_seen'] ?? 0) as int,
                (e['last_seen'] ?? 0) as int,
                (e['hits'] ?? 0) as int,
              ))
          .toList();
      final pending = list.where((e) => e.status == 'pending').length;
      if (_lastPending >= 0 && pending > _lastPending && mounted) {
        _notifyNewDevice(pending);
      }
      _lastPending = pending;
      setState(() {
        _items = list;
        _err = '';
      });
    } catch (e) {
      if (!quiet) setState(() => _err = '连接失败：$e');
    } finally {
      _busy = false;
    }
  }

  void _notifyNewDevice(int pending) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('有 $pending 台新设备待审批'),
      backgroundColor: Theme.of(context).colorScheme.error,
      duration: const Duration(seconds: 5),
      action: SnackBarAction(
          label: '刷新',
          textColor: Colors.white,
          onPressed: () => _refresh()),
    ));
  }

  Future<void> _decide(String id, String action) async {
    final url = _baseUrl();
    final token = bind.getLocalFlutterOption(k: kEnrollAdminToken).trim();
    try {
      final res = await http
          .post(Uri.parse(
              '$url/enroll/api/$action?token=${Uri.encodeQueryComponent(token)}&id=${Uri.encodeQueryComponent(id)}'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        setState(() => _err = '操作失败 ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _err = '操作失败：$e');
    }
    _refresh();
  }

  Future<void> _saveCfg() async {
    await bind.setLocalFlutterOption(k: kEnrollAdminUrl, v: _urlCtrl.text.trim());
    await bind.setLocalFlutterOption(k: kEnrollAdminToken, v: _tokenCtrl.text.trim());
    setState(() => _cfgOpen = false);
    _lastPending = -1;
    _refresh();
  }

  String _fmtTime(int t) {
    if (t <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final pending = _items.where((e) => e.status == 'pending').toList();
    final approved = _items.where((e) => e.status == 'approved').toList();
    final rejected = _items.where((e) => e.status == 'rejected').toList();
    final unconfigured =
        bind.getLocalFlutterOption(k: kEnrollAdminUrl).isEmpty;

    return Column(
      children: [
        _buildHeader(pending.length, approved.length, rejected.length),
        if (_cfgOpen) _buildCfgPanel(),
        Expanded(
          child: _err.isNotEmpty && _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_err, style: const TextStyle(color: Colors.redAccent)),
                      const SizedBox(height: 12),
                      _cfgButton('打开设置'),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    _section('待审批（${pending.length}）', Colors.orange, pending),
                    _section('已入网（${approved.length}）· 点击设备行即可远程连接', Colors.green, approved),
                    _section('已拒绝（${rejected.length}）', Colors.redAccent, rejected),
                    const SizedBox(height: 24),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _cfgButton([String? label]) => TextButton.icon(
      onPressed: () => setState(() => _cfgOpen = true),
      icon: const Icon(Icons.settings, size: 16),
      label: Text(label ?? '设置'));

  Widget _buildHeader(int p, int a, int r) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.fact_check,
              size: 20,
              color: p > 0 ? Colors.orange : Theme.of(context).disabledColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text('入网审批  ·  待审批 $p 台',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: p > 0 ? Colors.orange : null)),
          ),
          if (unconfigured) _cfgButton(),
          IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _refresh()),
          IconButton(
              tooltip: '审批服务器设置',
              icon: const Icon(Icons.settings, size: 18),
              onPressed: () => setState(() => _cfgOpen = !_cfgOpen)),
        ],
      ),
    );
  }

  Widget _buildCfgPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 90, child: Text('服务端地址')),
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  decoration:
                      const InputDecoration(hintText: '例如 http://49.235.111.81:21120'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 90, child: Text('Token')),
              Expanded(
                child: TextField(
                  controller: _tokenCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: '审批台令牌'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => setState(() => _cfgOpen = false), child: const Text('取消')),
              FilledButton(onPressed: _saveCfg, child: const Text('保存并连接')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title, Color color, List<_Entry> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title,
              style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text('（空）',
                style: TextStyle(fontSize: 12, color: Theme.of(context).disabledColor)),
          ),
        ...items.map((e) => _tile(e)),
      ],
    );
  }

  Widget _tile(_Entry e) {
    Widget? actions;
    if (e.status == 'pending') {
      actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
              onPressed: () => _decide(e.id, 'approve'),
              child: const Text('同意', style: TextStyle(color: Colors.green))),
          TextButton(
              onPressed: () => _decide(e.id, 'reject'),
              child: const Text('拒绝', style: TextStyle(color: Colors.redAccent))),
        ],
      );
    } else if (e.status == 'approved') {
      actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
              tooltip: '连接远程桌面',
              icon: const Icon(Icons.play_arrow, size: 20),
              onPressed: () => connect(context, e.id)),
          IconButton(
              tooltip: '文件传输',
              icon: const Icon(Icons.folder_outlined, size: 18),
              onPressed: () => connect(context, e.id, isFileTransfer: true)),
          IconButton(
              tooltip: '移出（需重新审批才可接入）',
              icon: const Icon(Icons.link_off, size: 16),
              onPressed: () => _decide(e.id, 'reject')),
          IconButton(
              tooltip: '删除记录',
              icon: const Icon(Icons.delete_outline, size: 16),
              onPressed: () => _decide(e.id, 'delete')),
        ],
      );
    } else {
      actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
              onPressed: () => _decide(e.id, 'approve'),
              child: const Text('恢复')),
          IconButton(
              tooltip: '删除记录',
              icon: const Icon(Icons.delete_outline, size: 16),
              onPressed: () => _decide(e.id, 'delete')),
        ],
      );
    }

    return ListTile(
      dense: true,
      leading: Icon(Icons.computer, size: 20, color: Theme.of(context).disabledColor),
      title: Text(e.id, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text('${e.ip}  ·  最近活动 ${_fmtTime(e.lastSeen)}'
          '${e.status == 'pending' ? '  ·  已尝试 ${e.hits} 次' : ''}',
          style: const TextStyle(fontSize: 12)),
      trailing: actions,
      // 已入网设备：点击整行直接发起远程连接
      onTap: e.status == 'approved' ? () => connect(context, e.id) : null,
    );
  }
}
