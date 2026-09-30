import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:markcut/services/purchase_service.dart';

PurchaseDetails purchase(String id, PurchaseStatus status) => PurchaseDetails(
  purchaseID: id,
  productID: 'tip_small',
  status: status,
  verificationData: PurchaseVerificationData(
    localVerificationData: '',
    serverVerificationData: '',
    source: 'test',
  ),
  transactionDate: '1',
)..pendingCompletePurchase = status != PurchaseStatus.pending;

void main() {
  test(
    'completes without a page listener and deduplicates store redelivery',
    () async {
      final input = StreamController<List<PurchaseDetails>>(sync: true);
      final completed = <String>[];
      final service = PurchaseService.forTest(
        purchases: input.stream,
        complete: (p) async {
          completed.add(p.purchaseID!);
        },
      );
      service.start();
      service.start();
      final ui = service.events.listen((_) {});
      input.add([purchase('one', PurchaseStatus.pending)]);
      await service.settled;
      await ui.cancel();
      input.add([purchase('one', PurchaseStatus.purchased)]);
      await service.settled;
      input.add([purchase('one', PurchaseStatus.purchased)]);
      await service.settled;
      expect(completed, ['one']);
      await service.dispose();
      await input.close();
    },
  );
  test(
    'completion failure is retained and retried without reopening the page',
    () async {
      final input = StreamController<List<PurchaseDetails>>(sync: true);
      var attempts = 0;
      final service = PurchaseService.forTest(
        purchases: input.stream,
        complete: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
        },
      );
      service.start();
      input.add([purchase('two', PurchaseStatus.purchased)]);
      await service.settled;
      service.retryPending();
      await service.settled;
      expect(attempts, 2);
      await service.dispose();
      await input.close();
    },
  );
}
