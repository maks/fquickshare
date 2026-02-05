import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/ui_event.dart';

typedef _StartServiceNative = Int32 Function(Pointer<Utf8>);
typedef _StartServiceDart = int Function(Pointer<Utf8>);

typedef _StopServiceNative = Int32 Function();
typedef _StopServiceDart = int Function();

typedef _AcceptTransferNative = Int32 Function(Pointer<Utf8>);
typedef _AcceptTransferDart = int Function(Pointer<Utf8>);

typedef _RejectTransferNative = Int32 Function(Pointer<Utf8>);
typedef _RejectTransferDart = int Function(Pointer<Utf8>);

typedef _CancelTransferNative = Int32 Function(Pointer<Utf8>);
typedef _CancelTransferDart = int Function(Pointer<Utf8>);

typedef _RegisterCallbackNative = Int32 Function(
  Pointer<NativeFunction<Void Function(Pointer<Uint8>, IntPtr)>>,
);
typedef _RegisterCallbackDart = int Function(
  Pointer<NativeFunction<Void Function(Pointer<Uint8>, IntPtr)>>,
);

typedef _ClearCallbackNative = Int32 Function();
typedef _ClearCallbackDart = int Function();

typedef _FreeEventPayloadNative = Void Function(Pointer<Int8>);
typedef _FreeEventPayloadDart = void Function(Pointer<Int8>);

class RqsFfi {
  static const String _defaultLibPath =
      '/home/maks/build/rquickshare/core_lib/target/debug/librqs_lib.so';

  late final DynamicLibrary _lib;
  late final _StartServiceDart _startService;
  late final _StopServiceDart _stopService;
  late final _AcceptTransferDart _acceptTransfer;
  late final _RejectTransferDart _rejectTransfer;
  late final _CancelTransferDart _cancelTransfer;
  late final _RegisterCallbackDart _registerCallback;
  late final _ClearCallbackDart _clearCallback;
  late final _FreeEventPayloadDart _freeEventPayload;

  final StreamController<UiEvent> _controller =
      StreamController<UiEvent>.broadcast();
  NativeCallable<Void Function(Pointer<Uint8>, IntPtr)>? _callbackHandle;

  RqsFfi() {
    if (!Platform.isLinux) {
      throw UnsupportedError('RqsFfi is only supported on Linux.');
    }
    final envPath = Platform.environment['RQS_LIB_PATH'];
    final candidate = envPath?.isNotEmpty == true ? envPath! : _defaultLibPath;
    _lib = DynamicLibrary.open(candidate);

    _startService =
        _lib.lookupFunction<_StartServiceNative, _StartServiceDart>(
      'rqs_start_service',
    );
    _stopService = _lib.lookupFunction<_StopServiceNative, _StopServiceDart>(
      'rqs_stop_service',
    );
    _acceptTransfer =
        _lib.lookupFunction<_AcceptTransferNative, _AcceptTransferDart>(
      'rqs_accept_transfer',
    );
    _rejectTransfer =
        _lib.lookupFunction<_RejectTransferNative, _RejectTransferDart>(
      'rqs_reject_transfer',
    );
    _cancelTransfer =
        _lib.lookupFunction<_CancelTransferNative, _CancelTransferDart>(
      'rqs_cancel_transfer',
    );
    _registerCallback =
        _lib.lookupFunction<_RegisterCallbackNative, _RegisterCallbackDart>(
      'rqs_register_event_callback',
    );
    _clearCallback =
        _lib.lookupFunction<_ClearCallbackNative, _ClearCallbackDart>(
      'rqs_clear_event_callback',
    );
    _freeEventPayload =
        _lib.lookupFunction<_FreeEventPayloadNative, _FreeEventPayloadDart>(
      'rqs_free_event_payload',
    );
  }

  Stream<UiEvent> get events => _controller.stream;

  int startService(String downloadDir) {
    _callbackHandle ??=
        NativeCallable<Void Function(Pointer<Uint8>, IntPtr)>.listener(_onEvent);
    _registerCallback(_callbackHandle!.nativeFunction);

    final cDir = downloadDir.toNativeUtf8();
    try {
      return _startService(cDir);
    } finally {
      malloc.free(cDir);
    }
  }

  int stopService() => _stopService();

  int acceptTransfer(String id) {
    final cId = id.toNativeUtf8();
    try {
      return _acceptTransfer(cId);
    } finally {
      malloc.free(cId);
    }
  }

  int rejectTransfer(String id) {
    final cId = id.toNativeUtf8();
    try {
      return _rejectTransfer(cId);
    } finally {
      malloc.free(cId);
    }
  }

  int cancelTransfer(String id) {
    final cId = id.toNativeUtf8();
    try {
      return _cancelTransfer(cId);
    } finally {
      malloc.free(cId);
    }
  }

  void dispose() {
    _clearCallback();
    _callbackHandle?.close();
    _callbackHandle = null;
    _controller.close();
    _stopService();
  }

  void _onEvent(Pointer<Uint8> message, int length) {
    if (length <= 0 || length > 1_000_000) {
      if (message != nullptr) {
        _freeEventPayload(message.cast<Int8>());
      }
      return;
    }
    try {
      final Pointer<Int8> payload = message.cast<Int8>();
      late final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(message.asTypedList(length));
      } finally {
        _freeEventPayload(payload);
      }
      final jsonStr = utf8.decode(bytes, allowMalformed: false);
      final data = jsonDecode(jsonStr);
      if (data is Map<String, dynamic>) {
        _controller.add(UiEvent.fromJson(data));
      }
    } on FormatException catch (error) {
      stderr.writeln(
        'rqs_ffi: invalid event payload (len=$length) - $error',
      );
    }
  }
}
