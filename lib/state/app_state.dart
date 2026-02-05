import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/rqs_service.dart';
import '../models/ui_event.dart';

class AppState extends ChangeNotifier {
  final RqsService _service;
  final List<UiEvent> _events = [];

  bool _autoAccept = false;
  bool _running = false;

  AppState()
      : _service = RqsService(
          RqsConfig(
            downloadDir: _resolveDownloadDir(),
            debug: _resolveDebug(),
          ),
        ) {
    _init();
  }

  List<UiEvent> get events => List.unmodifiable(_events);
  bool get autoAccept => _autoAccept;
  bool get running => _running;

  Future<void> _init() async {
    await _service.start();
    _running = _service.running;
    _service.events.listen(_handleEvent);
    notifyListeners();
  }

  void _handleEvent(UiEvent event) {
    final index = _events.indexWhere((e) => e.id == event.id);
    if (index == -1) {
      _events.insert(0, event);
    } else {
      _events[index] = event;
    }

    if (_autoAccept && event.isWaitingForConsent) {
      _service.acceptTransfer(event.id);
    }

    notifyListeners();
  }

  void setAutoAccept(bool value) {
    _autoAccept = value;
    if (_autoAccept) {
      for (final event in _events.where((e) => e.isWaitingForConsent)) {
        _service.acceptTransfer(event.id);
      }
    }
    notifyListeners();
  }

  void accept(String id) {
    _service.acceptTransfer(id);
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}

String _resolveDownloadDir() {
  const argPrefix = '--download-dir';
  final args = Platform.executableArguments;
  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    if (arg.startsWith('$argPrefix=')) {
      final value = arg.substring(argPrefix.length + 1).trim();
      if (value.isNotEmpty) {
        return value;
      }
    } else if (arg == argPrefix && i + 1 < args.length) {
      final value = args[i + 1].trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
  }

  final envOverride = Platform.environment['RQS_DOWNLOAD_DIR'];
  if (envOverride != null && envOverride.isNotEmpty) {
    return envOverride;
  }

  final home = Platform.environment['HOME'] ?? '/home/maks';
  return '$home/Downloads';
}

bool _resolveDebug() {
  final env = Platform.environment['RQS_DEBUG'];
  if (env == null) {
    return false;
  }
  return env == '1' || env.toLowerCase() == 'true';
}
