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
  @override
  void initState() {
    super.initState();
    subscription = PushKit.events.listen(
      (event) => setState(() => lastEvent = '${event.name}\n${event.data}'),
    );
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
          child: Text(lastEvent),
        ),
      ),
    ),
  );
}
