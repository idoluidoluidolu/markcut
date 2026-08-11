import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../theme.dart';

/// 斗內頁（App 內購小費罐）：三檔消耗型內購。
/// 商店後台（App Store Connect / Play Console）要先建立這三個
/// 消耗型商品，ID 如下；還沒建立/還沒上架時頁面會顯示「即將開放」
const kTipIds = <String>{'tip_small', 'tip_medium', 'tip_large'};

class DonateScreen extends StatefulWidget {
  const DonateScreen({super.key});

  @override
  State<DonateScreen> createState() => _DonateScreenState();
}

class _DonateScreenState extends State<DonateScreen> {
  final _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  List<ProductDetails> _products = const [];
  bool _loading = true;
  bool _buying = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      // 先掛監聽再查商品：買完的事件才不會漏接
      _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (!await _iap.isAvailable()) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final resp = await _iap.queryProductDetails(kTipIds);
      final list = resp.productDetails
        ..sort((a, b) => a.rawPrice.compareTo(b.rawPrice));
      if (mounted) {
        setState(() {
          _products = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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
        title: const Text('謝謝你的支持！'),
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

  Future<void> _buy(ProductDetails p) async {
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

  /// 檔位的圖示與說明（照價位排序後依序套用）
  static const _tiers = [
    (Icons.local_cafe_outlined, '請我們喝杯飲料'),
    (Icons.lunch_dining_outlined, '請我們吃份雞排'),
    (Icons.rocket_launch_outlined, '大力支持開發'),
  ];

  Widget _tierCard(int i, ProductDetails p) {
    final (icon, label) = _tiers[i.clamp(0, _tiers.length - 1)];
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: _buying ? null : () => _buy(p),
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
              child: Icon(icon, size: 22, color: kAmber),
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
              p.price,
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
                '謝謝你喜歡這個 App！',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                '這是我們用下班時間慢慢做出來的作品。\n'
                '如果它有幫上忙，可以請我們喝杯飲料，\n'
                '讓我們更有動力繼續加功能、修問題 🙌',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: kTextDim, height: 1.7),
              ),
              const SizedBox(height: 22),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_products.isEmpty)
                // web、模擬器、或商店商品還沒建好都會走到這
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: kPanel,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder, width: 1.5),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.storefront_outlined,
                          size: 26, color: kTextDim),
                      SizedBox(height: 8),
                      Text(
                        '斗內功能即將開放',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'App 上架商店後就能在這裡請我們喝飲料，\n現在最大的支持是把 App 分享給朋友！',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: kTextDim,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (var i = 0; i < _products.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _tierCard(i, _products[i]),
                ],
              const SizedBox(height: 18),
              const Text(
                '斗內屬於自願贊助，不會解鎖額外功能',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: kTextDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
