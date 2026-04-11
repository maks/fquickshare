import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'state/app_state.dart';

void main() {
  runApp(const FquickshareApp());
}

class FquickshareApp extends StatelessWidget {
  const FquickshareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: 'FQuickShare',
        theme: ThemeData(useMaterial3: true),
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FQuickShare')),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.running
                            ? 'Service: Running'
                            : 'Service: Not running',
                      ),
                    ),
                    Row(
                      children: [
                        const Text('Auto-accept'),
                        Switch(
                          value: state.autoAccept,
                          onChanged: state.setAutoAccept,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: state.events.isEmpty
                    ? const Center(child: Text('Waiting for transfers...'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: state.events.length,
                        itemBuilder: (context, index) {
                          final event = state.events[index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          event.sourceName ?? 'Unknown device',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                      Text(
                                        event.state ?? 'Unknown',
                                        style: event.state == 'Finished'
                                            ? Theme.of(
                                                context,
                                              ).textTheme.titleMedium?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              )
                                            : null,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (event.files.isNotEmpty) ...[
                                    Text('Files: ${event.files.join(', ')}'),
                                    const SizedBox(height: 6),
                                  ],
                                  if (event.url != null) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            event.url!,
                                            style: const TextStyle(
                                              color: Colors.blue,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            final uri = Uri.tryParse(
                                              event.url!,
                                            );
                                            if (uri != null) {
                                              launchUrl(uri);
                                            }
                                          },
                                          child: const Text('Open'),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (event.destination != null)
                                    Text('Destination: ${event.destination}'),
                                  if (event.pinCode != null)
                                    Text('PIN: ${event.pinCode}'),
                                  if (event.totalBytes > 0)
                                    Text(
                                      'Progress: ${_formatBytes(event.ackBytes)} / ${_formatBytes(event.totalBytes)}',
                                    ),
                                  if (event.isWaitingForConsent &&
                                      !state.autoAccept)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: ElevatedButton(
                                        onPressed: () {
                                          state.accept(event.id);
                                        },
                                        child: const Text('Accept'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    if (mb < 1024) {
      return '${mb.toStringAsFixed(1)} MB';
    }
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }
}
