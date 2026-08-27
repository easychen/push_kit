import 'package:flutter_test/flutter_test.dart';
import 'package:push_kit/push_kit.dart';

void main() {
  test('event names are stable public API', () {
    expect(PushEventName.receiveNotification, 'push.receiveNotification');
    expect(PushEventName.openNotification, 'push.openNotification');
    expect(PushEventName.localNotification, 'push.localNotification');
  });

  test('event maps are decoded', () {
    final event = PushEvent.fromMap({
      'name': 'push.receiveNotification',
      'data': {'messageType': 'data'},
    });
    expect(event.name, 'push.receiveNotification');
    expect(event.data['messageType'], 'data');
  });
}
