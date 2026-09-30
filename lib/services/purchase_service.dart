import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// Store transactions outlive routes. Keep completion, retries and UI events separate.
class PurchaseService with WidgetsBindingObserver {
  PurchaseService._();
  static final instance = PurchaseService._();
  @visibleForTesting
  PurchaseService.forTest({
    required Stream<List<PurchaseDetails>> purchases,
    required Future<void> Function(PurchaseDetails) complete,
  }) : _testPurchases = purchases,
       _testComplete = complete;

  Stream<List<PurchaseDetails>>? _testPurchases;
  Future<void> Function(PurchaseDetails)? _testComplete;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final _events = StreamController<List<PurchaseDetails>>.broadcast();
  final _pending = <String, PurchaseDetails>{};
  final _completed = <String>{};
  Future<void> _tail = Future.value();
  Timer? _retry;
  bool _observing = false;
  Stream<List<PurchaseDetails>> get events => _events.stream;

  void start() {
    if (_subscription != null || kIsWeb) return;
    if (_testPurchases == null &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    try {
      _subscription = (_testPurchases ?? InAppPurchase.instance.purchaseStream)
          .listen((purchases) {
            _tail = _tail.then((_) => _handle(purchases)).catchError((_) {});
          }, onError: (_) => _scheduleRetry());
      if (_testPurchases == null) {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      }
    } catch (_) {
      _subscription = null;
    }
  }

  String _key(PurchaseDetails p) =>
      '${p.productID}:${p.purchaseID ?? p.transactionDate ?? identityHashCode(p)}';

  Future<void> _handle(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.pending) continue;
      if (p.pendingCompletePurchase && !_completed.contains(_key(p))) {
        _pending[_key(p)] = p;
      }
    }
    await _finishPending();
    if (!_events.isClosed) _events.add(purchases);
  }

  Future<void> _finishPending() async {
    for (final entry in _pending.entries.toList()) {
      try {
        await (_testComplete ?? InAppPurchase.instance.completePurchase)(
          entry.value,
        );
        _pending.remove(entry.key);
        _completed.add(entry.key);
        if (_completed.length > 256) _completed.remove(_completed.first);
      } catch (_) {
        /* Keep the transaction for retry; never lose it with the page. */
      }
    }
    if (_pending.isNotEmpty) _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry ??= Timer(const Duration(seconds: 30), () {
      _retry = null;
      retryPending();
    });
  }

  void retryPending() {
    _tail = _tail.then((_) => _finishPending()).catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) retryPending();
  }

  @visibleForTesting
  Future<void> get settled => _tail;

  @visibleForTesting
  Future<void> dispose() async {
    _retry?.cancel();
    await _subscription?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    await _tail;
    _retry?.cancel();
    await _events.close();
  }
}
