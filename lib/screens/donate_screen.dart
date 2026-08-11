import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../theme.dart';

/// 斗內頁（App 內購小費罐）。
///
/// 內購：三檔消耗型商品，商店後台要建立同 ID 的商品才買得動；
/// 還沒建立時卡片照樣顯示（固定價），點了提示即將開放。
const kTipIds = <String>{'tip_small', 'tip_medium', 'tip_large'};

/// 檔位定義：(商品 ID, 名稱, 沒抓到商店價時顯示的價格)
const _kTiers = [
  ('tip_small', '小挺一下', 'NT\$100'),
  ('tip_medium', '中挺一下', 'NT\$500'),
  ('tip_large', '大挺一下', 'NT\$990'),
];


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

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      // 先掛監聽再查商品：買完的事件才不會漏接
      _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
      _loadProducts();
    }
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

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        if (p.pendingCompletePurchase) await _iap.completePurchase(p);
        if (mounted) {
          setState(() => _buying = false);
          _thanks();
        }
      } else if (p.status == PurchaseStatus.error ||
          p.status == PurchaseStatus.canceled) {
        if (p.pendingCompletePurchase) await _iap.completePurchase(p);
        if (mounted) setState(() => _buying = false);
      }
    }
  }

  void _thanks() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('謝謝你的加菜金！🙏'),
        content: const Text('每一份心意都會變成我們繼續改進的動力 💪'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('好'),
          ),
        ],
      ),
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
    'medium': Icons.ramen_dining_outlined,
    'large': Icons.rocket_launch_outlined,
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
            ],
          ),
        ),
      ),
    );
  }
}
