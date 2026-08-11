import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// 斗內頁（App 內購小費罐）＋斗內牆。
///
/// 內購：三檔消耗型商品，商店後台要建立同 ID 的商品才買得動；
/// 還沒建立時卡片照樣顯示（固定價），點了提示即將開放。
/// 斗內牆：目前是「假資料＋本機紀錄」——自己斗內成功會記在本機
/// 並上牆；之後要做真的再接後端（全部人共用的牆）。
const kTipIds = <String>{'tip_small', 'tip_medium', 'tip_large'};

/// 檔位定義：(商品 ID, 名稱, 沒抓到商店價時顯示的價格)
const _kTiers = [
  ('tip_small', '小挺一下', 'NT\$100'),
  ('tip_medium', '中挺一下', 'NT\$500'),
  ('tip_large', '大挺一下', 'NT\$990'),
];

const _kLocalTipsKey = 'my_tips';

class DonateScreen extends StatefulWidget {
  const DonateScreen({super.key});

  @override
  State<DonateScreen> createState() => _DonateScreenState();
}

class _DonateScreenState extends State<DonateScreen> {
  final _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, ProductDetails> _products = {};
  bool _buying = false;

  /// 斗內牆：假資料墊底（之後接後端換成真的），
  /// 自己的斗內紀錄（本機）疊在最上面
  static const _seedWall = [
    ('剪', '剪片路過的', 'small'),
    ('神', '神秘人', 'medium'),
    ('阿', '阿偉', 'small'),
    ('浮', '浮水印重度使用者', 'large'),
    ('小', '小美', 'small'),
  ];
  List<(String, String, String)> _myTips = [];

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      // 先掛監聽再查商品：買完的事件才不會漏接
      _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
      _loadProducts();
    }
    _loadMyTips();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    try {
      if (!await _iap.isAvailable()) return;
      final resp = await _iap.queryProductDetails(kTipIds);
      if (mounted) {
        setState(() {
          for (final p in resp.productDetails) {
            _products[p.id] = p;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _loadMyTips() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLocalTipsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map(
            (m) => (
              (m['name'] as String? ?? '無名氏').isEmpty
                  ? '無'
                  : (m['name'] as String)[0],
              m['name'] as String? ?? '無名氏',
              m['tier'] as String? ?? 'small',
            ),
          )
          .toList();
      if (mounted) setState(() => _myTips = list);
    } catch (_) {}
  }

  Future<void> _saveMyTip(String name, String tier) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLocalTipsKey);
    List<dynamic> list = [];
    try {
      if (raw != null) list = jsonDecode(raw) as List;
    } catch (_) {}
    list.insert(0, {'name': name, 'tier': tier});
    await prefs.setString(_kLocalTipsKey, jsonEncode(list));
    _loadMyTips();
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        if (p.pendingCompletePurchase) await _iap.completePurchase(p);
        if (mounted) {
          setState(() => _buying = false);
          final tier = p.productID.replaceFirst('tip_', '');
          _askNameAndThank(tier);
        }
      } else if (p.status == PurchaseStatus.error ||
          p.status == PurchaseStatus.canceled) {
        if (p.pendingCompletePurchase) await _iap.completePurchase(p);
        if (mounted) setState(() => _buying = false);
      }
    }
  }

  /// 斗內成功：問一個顯示名稱（選填）→ 上牆＋道謝
  Future<void> _askNameAndThank(String tier) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('謝謝你的加菜金！🙏'),
        content: TextField(
          controller: ctrl,
          maxLength: 12,
          decoration: const InputDecoration(
            hintText: '想在斗內牆上顯示的名字（選填）',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('上牆！'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    await _saveMyTip(
      (name == null || name.isEmpty) ? '無名氏' : name,
      tier,
    );
  }

  Future<void> _buy(String id) async {
    final p = _products[id];
    if (p == null) {
      // 商店商品還沒建立（未上架）或 web：先收下心意
      showHint(context, '斗內功能上架商店後開放，先謝謝你的心意！');
      return;
    }
    if (_buying) return;
    setState(() => _buying = true);
    try {
      await _iap.buyConsumable(
        purchaseParam: PurchaseParam(productDetails: p),
      );
    } catch (_) {
      if (mounted) setState(() => _buying = false);
    }
  }

  static const _tierIcons = {
    'small': Icons.local_cafe_outlined,
    'medium': Icons.lunch_dining_outlined,
    'large': Icons.rocket_launch_outlined,
  };
  static const _tierNames = {
    'small': '小挺一下',
    'medium': '中挺一下',
    'large': '大挺一下',
  };

  Widget _tierCard(String id, String label, String fallbackPrice) {
    final tier = id.replaceFirst('tip_', '');
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: _buying ? null : () => _buy(id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: kPanelHi,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_tierIcons[tier], size: 22, color: kAmber),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              _products[id]?.price ?? fallbackPrice,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: kAmber,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wallRow(String name, String tier, {bool mine = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPanelHi,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(_tierIcons[tier], size: 15, color: kAmber),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (mine)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kSelect.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                '你',
                style: TextStyle(fontSize: 10, color: kSelect),
              ),
            ),
          Text(
            _tierNames[tier] ?? '',
            style: const TextStyle(fontSize: 11.5, color: kTextDim),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, title: const Text('太好用啦')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: SizedBox(
                  width: 160,
                  height: 64,
                  child: Image.asset(
                    'assets/icon/home_logo.png',
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '真的那麼好用？',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                '好用到會想給我一點加菜金？\n'
                '如果你想斗內的話，\n'
                '那我當然是不會拒絕的！',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: kTextDim, height: 1.7),
              ),
              const SizedBox(height: 22),
              for (final (id, label, price) in _kTiers) ...[
                _tierCard(id, label, price),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              const Text(
                '斗內屬於自願贊助，不會解鎖額外功能',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: kTextDim),
              ),
              const SizedBox(height: 26),
              // ===== 斗內牆 =====
              Row(
                children: [
                  const Icon(Icons.emoji_events_outlined,
                      size: 17, color: kAmber),
                  const SizedBox(width: 7),
                  const Text(
                    '斗內牆',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  Text(
                    '感謝每一位',
                    style: const TextStyle(fontSize: 11, color: kTextDim),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: kPanel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder, width: 1.5),
                ),
                child: Column(
                  children: [
                    for (final (_, name, tier) in _myTips)
                      _wallRow(name, tier, mine: true),
                    for (final (_, name, tier) in _seedWall)
                      _wallRow(name, tier),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
