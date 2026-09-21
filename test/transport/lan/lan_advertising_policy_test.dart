import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/lan/lan_advertising_policy.dart';
import 'package:viska/src/transport/p2p_transport.dart';

void main() {
  group('AlwaysAdvertisePolicy', () {
    test('always returns true', () {
      const policy = AlwaysAdvertisePolicy();
      expect(policy.shouldAdvertise(ContactId([1, 2, 3])), isTrue);
    });
  });

  group('ActiveContactsAdvertisingPolicy', () {
    test('does not advertise contact never marked active', () {
      final policy = ActiveContactsAdvertisingPolicy();
      expect(policy.shouldAdvertise(ContactId([1])), isFalse);
    });

    test('advertises contact marked active within ttl', () {
      var now = DateTime(2026, 1, 1, 12);
      final policy = ActiveContactsAdvertisingPolicy(
        ttl: const Duration(minutes: 5),
        now: () => now,
      );
      final contact = ContactId([1]);

      policy.markActive(contact);
      now = now.add(const Duration(minutes: 4));

      expect(policy.shouldAdvertise(contact), isTrue);
    });

    test('stops advertising after ttl expires', () {
      var now = DateTime(2026, 1, 1, 12);
      final policy = ActiveContactsAdvertisingPolicy(
        ttl: const Duration(minutes: 5),
        now: () => now,
      );
      final contact = ContactId([1]);

      policy.markActive(contact);
      now = now.add(const Duration(minutes: 6));

      expect(policy.shouldAdvertise(contact), isFalse);
    });

    test('markInactive stops advertising immediately', () {
      final policy = ActiveContactsAdvertisingPolicy();
      final contact = ContactId([1]);

      policy.markActive(contact);
      expect(policy.shouldAdvertise(contact), isTrue);

      policy.markInactive(contact);
      expect(policy.shouldAdvertise(contact), isFalse);
    });

    test('different contacts do not affect each other', () {
      final policy = ActiveContactsAdvertisingPolicy();
      final alice = ContactId([1]);
      final bob = ContactId([2]);

      policy.markActive(alice);

      expect(policy.shouldAdvertise(alice), isTrue);
      expect(policy.shouldAdvertise(bob), isFalse);
    });
  });
}
