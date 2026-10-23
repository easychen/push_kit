import 'dart:async';
import 'package:flutter/material.dart';
import 'package:push_kit/push_kit.dart';

void main() => runApp(const PushExample());

class PushExample extends StatefulWidget {
  const PushExample({super.key});
  @override
  State<PushExample> createState() => _PushExampleState();
}

class _PushExampleState extends State<PushExample> {
  StreamSubscription<PushEvent>? subscription;
  String lastEvent = 'No events';
  String status = '';

  @override
  void initState() {
    super.initState();
    subscription = PushKit.events.listen(
      (event) => setState(() => lastEvent = '${event.name}\n${event.data}'),
    );
  }

  Future<void> run(Future<String> Function() action) async {
    try {
      final String message = await action();
      if (mounted) {
        setState(() => status = message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => status = '$error');
      }
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('push_kit')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(lastEvent, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Text(status, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  FilledButton(
                    onPressed: () =>
                        run(PushKit.checkNotificationPermission),
                    child: const Text('Check permission'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        run(PushKit.requestNotificationPermission),
                    child: const Text('Request permission'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final String? token = await PushKit.hwGetToken();
                      if (mounted) {
                        setState(() => status = 'token: $token');
                      }
                    },
                    child: const Text('Get push token'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
