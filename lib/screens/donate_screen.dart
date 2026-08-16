import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../theme.dart';
import '../widgets/swipe_back.dart';

/// 斗內頁（App 內購小費罐）。
///
/// 內購：四檔消耗型商品，商店後台要建立同 ID 的商品才買得動；
/// 還沒建立時卡片照樣顯示（固定價），點了提示即將開放。
const kTipIds = <String>{
  'tip_small',
  'tip_medium',
  'tip_large',
  'tip_max',
};

/// 前三檔並排：(商品 ID, 名稱, 沒抓到商店價時顯示的價格)
const _kTiers = [
  ('tip_small', '小挺一下', 'NT\$100'),
  ('tip_medium', '中挺一下', 'NT\$300'),
  ('tip_large', '大挺一下', 'NT\$500'),
];

/// 最下面那一檔，整排寬
const _kMaxTier = ('tip_max', '極限挺', 'NT\$990');

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
    var thanked = false;
    for (final p in purchases) {
      // pending（待付款、家長核准…）：不是終局，但按鈕不能一直鎖著，
      // 否則三個檔位全部按不動，畫面上又沒有任何說明
      if (p.status == PurchaseStatus.pending) {
        if (mounted) setState(() => _buying = false);
        continue;
      }
      if (p.pendingCompletePurchase) await _iap.completePurchase(p);
      if (!mounted) return;
      setState(() => _buying = false);
      if (p.status == PurchaseStatus.purchased) {
        // 一次收到好幾筆只謝一次，不然感謝視窗會疊好幾層
        if (!thanked) {
          thanked = true;
          _thanks();
        }
      }
      // restored：補送的舊交易，completePurchase 收乾淨就好，
      // 不要在使用者一進頁面時莫名跳出感謝視窗
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
      await _iap.buyConsumable(purchaseParam: PurchaseParam(productDetails: p));
    } catch (_) {
      if (mounted) setState(() => _buying = false);
    }
  }

  /// 並排的一張：金額是主角，名稱在下面。
  /// [strong] 是推薦的那一檔，直接填深色
  Widget _tierCard(
    String id,
    String label,
    String fallbackPrice, {
    bool strong = false,
  }) {
    final price = _products[id]?.price ?? fallbackPrice;
    // 「NT$300」拆成幣別與數字：數字要夠大才好比較，幣別只是註記。
    // 從第一個數字切開，別把小數點的錢（US$3.99）拆成 399
    final cut = price.indexOf(RegExp(r'\d'));
    final unit = cut <= 0 ? '' : price.substring(0, cut).trim();
    final digits = cut < 0 ? price : price.substring(cut).trim();
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _buying ? null : () => _buy(id),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: strong ? kLAccent : kLCard,
            borderRadius: BorderRadius.circular(20),
            border: strong ? null : Border.all(color: kLBorder, width: 1.4),
          ),
          child: Column(
            children: [
              // 換個幣別可能是「30,000」這種長數字，卡片只有三分之一
              // 螢幕寬——縮著顯示，不要爆版
              FittedBox(
                child: Text(
                  digits,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    color: strong ? Colors.white : kLText,
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: strong
                        ? Colors.white.withValues(alpha: 0.7)
                        : kLTextDim,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: strong ? Colors.white : kLText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 最下面那一檔：整排寬，金額跟名稱並排
  Widget _maxTierCard() {
    final (id, label, fallback) = _kMaxTier;
    final price = _products[id]?.price ?? fallback;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: _buying ? null : () => _buy(id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
        decoration: BoxDecoration(
          color: kLCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kLAccent, width: 1.8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    '這個我會記很久',
                    style: TextStyle(fontSize: 12.5, color: kLTextDim),
                  ),
                ],
              ),
            ),
            Text(
              price,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
      backgroundColor: kLBg,
      appBar: AppBar(backgroundColor: kLBg, title: const Text('太好用啦')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              // 內容垂直置中；畫面太矮放不下才變成可捲
              child: LayoutBuilder(
                builder: (context, cons) => SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: cons.maxHeight),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '真的那麼好用？',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '好用到會想給我一點加菜金？\n'
                          '如果你想斗內的話，\n'
                          '那我當然是不會拒絕的！',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: kLTextDim,
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            for (var i = 0; i < _kTiers.length; i++) ...[
                              if (i > 0) const SizedBox(width: 10),
                              _tierCard(
                                _kTiers[i].$1,
                                _kTiers[i].$2,
                                _kTiers[i].$3,
                                // 中間那檔當推薦：三選一時人會挑中間的，
                                // 直接標出來省得猶豫
                                strong: i == 1,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        _maxTierCard(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // logo 釘在畫面底部置中（不跟內容捲動）
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: SizedBox(
                width: 120,
                height: 48,
                child: Image.asset(
                  'assets/icon/home_logo.png',
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}
