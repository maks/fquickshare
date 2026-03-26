import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:fixnum/fixnum.dart';

import '../models/ui_event.dart';
import 'crypto/nearby_crypto.dart';
import 'proto/device_to_device_messages.pb.dart' as d2d;
import 'proto/securemessage.pb.dart' as sm;
import 'proto/offline_wire_formats.pb.dart' as lnc;
import 'proto/ukey.pb.dart' as ukey;
import 'proto/wire_format.pb.dart' as sn;
import 'proto/securegcm.pb.dart' as gcm;
import 'discovery/mdns_advertiser.dart';
import 'discovery/mdns_discovery.dart';
import 'models/device_type.dart';
import 'transport/tcp_transport.dart';
import 'utils/crypto_utils.dart';
import 'utils/mdns_utils.dart';

class RqsConfig {
  final String downloadDir;
  final bool debug;

  const RqsConfig({required this.downloadDir, this.debug = false});
}

class RqsService {
  final RqsConfig config;
  final StreamController<UiEvent> _events =
      StreamController<UiEvent>.broadcast();

  bool _running = false;
  bool get _debug => config.debug;
  final TcpTransport _transport = TcpTransport();
  final MdnsAdvertiser _advertiser = MdnsAdvertiser();
  final MdnsDiscovery _discovery = MdnsDiscovery();
  late final Uint8List _endpointId;
  StreamSubscription? _connectionSub;
  final Map<String, UiEvent> _active = {};
  final Map<String, _ConnectionState> _connections = {};

  RqsService(this.config) {
    _endpointId = randomBytes(4);
  }

  Stream<UiEvent> get events => _events.stream;
  bool get running => _running;

  Future<void> start() async {
    if (_running) {
      return;
    }
    final port = await _transport.startServer();
    await _advertiser.start(
      port: port,
      endpointId: _endpointId,
      deviceType: DeviceType.laptop,
    );
    await _discovery.start();
    _connectionSub = _transport.connections.listen(_handleConnection);
    _running = true;
    _log('Service started');
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    await _connectionSub?.cancel();
    _connectionSub = null;
    for (final connection in _connections.values) {
      await connection.socket.close();
    }
    _connections.clear();
    await _discovery.stop();
    await _advertiser.stop();
    await _transport.stopServer();
    _running = false;
    _log('Service stopped');
  }

  void acceptTransfer(String id) {
    final existing = _active[id];
    final connection = _connections[id];
    if (existing == null || connection == null) {
      return;
    }
    _emit(existing.copyWith(state: 'ReceivingFiles'));
    connection.desiredResponse = true;
    _maybeSendConnectionResponse(connection);
  }

  void rejectTransfer(String id) {
    final existing = _active[id];
    final connection = _connections[id];
    if (existing == null || connection == null) {
      return;
    }
    _emit(existing.copyWith(state: 'Rejected'));
    connection.desiredResponse = false;
    _maybeSendConnectionResponse(connection);
  }

  void cancelTransfer(String id) {
    final existing = _active[id];
    final connection = _connections[id];
    if (existing == null || connection == null) {
      return;
    }
    _emit(existing.copyWith(state: 'Cancelled'));
    _closeSocket(id);
  }

  void dispose() {
    stop();
    _events.close();
  }

  void _handleConnection(Socket socket) {
    final remote = socket.remoteAddress.address;
    final port = socket.remotePort.toString();
    final id = '$remote:$port';
    final connection = _ConnectionState(id: id, socket: socket);
    _connections[id] = connection;
    _log('Connection accepted: $id');
    final event = UiEvent(
      id: id,
      state: 'WaitingForUserConsent',
      sourceName: remote,
      destination: config.downloadDir,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    _emit(event);

    final buffer = BytesBuilder(copy: false);
    socket.listen(
      (data) {
        buffer.add(data);
        _drainFrames(connection, buffer);
      },
      onError: (_) {
        _log('Socket error for $id');
        _emit(_active[id]?.copyWith(state: 'Error') ?? event);
        _closeSocket(id);
      },
      onDone: () {
        _log('Socket closed for $id');
        if (connection.files.isEmpty && !connection.finished) {
          final existing = _active[id];
          if (existing != null) {
            _emit(
              existing.copyWith(
                state: 'Finished',
                ackBytes: existing.totalBytes,
              ),
            );
          }
          connection.finished = true;
        } else if (connection.files.isNotEmpty) {
          for (final info in connection.files.values) {
            if (!info.warnedIncomplete) {
              _log(
                'Socket closed before file complete id=${info.id} received=${info.bytesTransferred} total=${info.totalSize}',
              );
              info.warnedIncomplete = true;
            }
          }
        }
        _closeSocket(id);
      },
      cancelOnError: true,
    );
  }

  void _emit(UiEvent event) {
    _active[event.id] = event;
    _log(
      'Emit UI event id=${event.id} state=${event.state} ack=${event.ackBytes} total=${event.totalBytes}',
    );
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _drainFrames(_ConnectionState connection, BytesBuilder buffer) {
    final bytes = buffer.toBytes();
    var offset = 0;
    while (offset + 4 <= bytes.length) {
      final length =
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      if (length < 0 || length > 5 * 1024 * 1024) {
        break;
      }
      final end = offset + 4 + length;
      if (end > bytes.length) {
        break;
      }
      final frame = bytes.sublist(offset + 4, end);
      _log('Frame ${frame.length} bytes from ${connection.id}');
      connection.processing = connection.processing.then(
        (_) => _handleFrame(connection, frame),
      );
      offset = end;
    }
    if (offset == 0) {
      return;
    }
    final remaining = bytes.sublist(offset);
    buffer.clear();
    buffer.add(remaining);
  }

  void _closeSocket(String id) {
    final connection = _connections.remove(id);
    connection?.socket.close();
  }

  Future<void> _handleFrame(
    _ConnectionState connection,
    Uint8List frame,
  ) async {
    if (connection.stage == _HandshakeStage.awaitingClientInit ||
        connection.stage == _HandshakeStage.awaitingClientFinish) {
      if (await _handleUkey2Message(connection, frame)) {
        return;
      }
    }

    if (connection.stage == _HandshakeStage.completed) {
      await _handleSecureMessage(connection, frame);
      await _handleSharingNearby(connection, frame);
      return;
    }

    try {
      final offline = lnc.OfflineFrame.fromBuffer(frame);
      if (!offline.hasV1()) {
        return;
      }
      final v1 = offline.v1;
      _log('OfflineFrame ${v1.type.name} from ${connection.id}');
      switch (v1.type) {
        case lnc.V1Frame_FrameType.CONNECTION_REQUEST:
          if (v1.hasConnectionRequest()) {
            _handleConnectionRequest(connection, v1.connectionRequest);
          }
          break;
        case lnc.V1Frame_FrameType.CONNECTION_RESPONSE:
          if (v1.hasConnectionResponse()) {
            _handleConnectionResponse(connection, v1.connectionResponse);
          }
          break;
        case lnc.V1Frame_FrameType.PAYLOAD_TRANSFER:
          if (v1.hasPayloadTransfer()) {
            await _handlePayloadTransfer(connection, v1.payloadTransfer);
          }
          break;
        default:
          break;
      }
      return;
    } catch (_) {
      // Not an OfflineFrame; continue.
    }

    if (connection.stage == _HandshakeStage.awaitingConnectionResponse) {
      if (await _handleUkey2Message(connection, frame)) {
        return;
      }
    }
    await _handleSecureMessage(connection, frame);
    await _handleSharingNearby(connection, frame);
  }

  void _handleConnectionRequest(
    _ConnectionState connection,
    lnc.ConnectionRequestFrame request,
  ) {
    if (connection.stage != _HandshakeStage.awaitingConnectionRequest) {
      return;
    }
    if (request.endpointInfo.isEmpty) {
      return;
    }
    try {
      final info = parseEndpointInfoBytes(
        Uint8List.fromList(request.endpointInfo),
      );
      final existing = _active[connection.id];
      if (existing != null) {
        _emit(existing.copyWith(sourceName: info.name));
      }
      connection.stage = _HandshakeStage.awaitingClientInit;
      _log('Handshake -> awaitingClientInit for ${connection.id}');
    } catch (e, st) {
      _log('SecureMessage decode failed: $e');
      _log('SecureMessage decode stack: $st');
      return;
    }
  }

  void _handleConnectionResponse(
    _ConnectionState connection,
    lnc.ConnectionResponseFrame response,
  ) {
    if (connection.stage == _HandshakeStage.awaitingConnectionResponse) {
      _log('ConnectionResponse received from ${connection.id}');
      connection.receivedConnectionResponse = true;
      _maybeSendConnectionResponse(connection);
    }
  }

  void _maybeSendConnectionResponse(_ConnectionState connection) {
    if (connection.stage != _HandshakeStage.awaitingConnectionResponse) {
      return;
    }
    final desired = connection.desiredResponse;
    if (desired == null || !connection.receivedConnectionResponse) {
      return;
    }
    unawaited(_sendConnectionResponse(connection, accept: desired));
  }

  Future<void> _sendConnectionResponse(
    _ConnectionState connection, {
    required bool accept,
  }) async {
    if (connection.sentResponse) {
      return;
    }
    connection.sentResponse = true;
    _log(
      'Sending ConnectionResponse ${accept ? "ACCEPT" : "REJECT"} to ${connection.id}',
    );
    final response = lnc.OfflineFrame(
      version: lnc.OfflineFrame_Version.V1,
      v1: lnc.V1Frame(
        type: lnc.V1Frame_FrameType.CONNECTION_RESPONSE,
        connectionResponse: lnc.ConnectionResponseFrame(
          response: accept
              ? lnc.ConnectionResponseFrame_ResponseStatus.ACCEPT
              : lnc.ConnectionResponseFrame_ResponseStatus.REJECT,
          osInfo: lnc.OsInfo(type: lnc.OsInfo_OsType.LINUX),
        ),
      ),
    );
    await _sendFrame(connection.socket, response.writeToBuffer());
    connection.sharingStage = _SharingStage.sentConnectionResponse;
    connection.stage = _HandshakeStage.completed;
    await _sendPairedKeyEncryption(connection);
  }

  Future<void> _sendFrame(Socket socket, Uint8List payload) async {
    final length = payload.length;
    final header = Uint8List(4);
    header[0] = (length >> 24) & 0xFF;
    header[1] = (length >> 16) & 0xFF;
    header[2] = (length >> 8) & 0xFF;
    header[3] = length & 0xFF;
    try {
      socket.add(header);
      socket.add(payload);
      await socket.flush();
      _log('Sent frame ${payload.length} bytes');
    } catch (e) {
      _log('Send frame failed: $e');
    }
  }

  Future<void> _handleSecureMessage(
    _ConnectionState connection,
    Uint8List frame,
  ) async {
    if (connection.decryptKey == null || connection.recvHmacKey == null) {
      return;
    }
    try {
      final smsg = sm.SecureMessage.fromBuffer(frame);
      final hmac = await Hmac.sha256().calculateMac(
        smsg.headerAndBody,
        secretKey: SecretKey(connection.recvHmacKey!),
      );
      if (!_constantTimeEquals(hmac.bytes, smsg.signature)) {
        _log('SecureMessage HMAC mismatch for ${connection.id}');
        return;
      }
      final headerAndBody = sm.HeaderAndBody.fromBuffer(smsg.headerAndBody);
      final iv = headerAndBody.header.iv;
      if (iv.length != 16) {
        _log('SecureMessage bad IV length ${iv.length} for ${connection.id}');
        return;
      }
      final cipherText = headerAndBody.body;

      final aes = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);
      final secretBox = SecretBox(cipherText, nonce: iv, mac: Mac.empty);
      final clearText = await aes.decrypt(
        secretBox,
        secretKey: SecretKey(connection.decryptKey!),
      );

      final d2dMsg = d2d.DeviceToDeviceMessage.fromBuffer(clearText);
      _log(
        'SecureMessage decoded seq=${d2dMsg.sequenceNumber} msg=${d2dMsg.message.length} bytes from ${connection.id}',
      );
      connection.expectedClientSeq += 1;
      final expected = connection.expectedClientSeq;
      final seq = d2dMsg.sequenceNumber;
      if (seq != expected) {
        _log('D2D seq mismatch $seq != $expected for ${connection.id}');
        return;
      }
      final offline = lnc.OfflineFrame.fromBuffer(d2dMsg.message);
      final v1 = offline.v1;
      _log('SecureMessage offline ${v1.type.name} from ${connection.id}');
      if (v1.type == lnc.V1Frame_FrameType.PAYLOAD_TRANSFER &&
          v1.hasPayloadTransfer()) {
        await _handlePayloadTransfer(connection, v1.payloadTransfer);
      }
    } catch (_) {
      return;
    }
  }

  Future<void> _handleSharingNearby(
    _ConnectionState connection,
    Uint8List frame,
  ) async {
    await _handleSharingNearbyBytes(connection, frame);
  }

  Future<void> _handleSharingNearbyBytes(
    _ConnectionState connection,
    Uint8List data,
  ) async {
    try {
      final snFrame = sn.Frame.fromBuffer(data);
      if (!snFrame.hasV1()) {
        return;
      }
      final v1 = snFrame.v1;
      _log('Sharing frame ${v1.type.name} from ${connection.id}');
      switch (v1.type) {
        case sn.V1Frame_FrameType.PAIRED_KEY_ENCRYPTION:
          if (v1.hasPairedKeyEncryption()) {
            await _handlePairedKeyEncryption(connection);
          }
          break;
        case sn.V1Frame_FrameType.PAIRED_KEY_RESULT:
          if (v1.hasPairedKeyResult()) {
            connection.sharingStage = _SharingStage.receivedPairedKeyResult;
          }
          break;
        case sn.V1Frame_FrameType.INTRODUCTION:
          if (v1.hasIntroduction()) {
            await _handleIntroduction(connection, v1.introduction);
          }
          break;
        default:
          break;
      }
    } catch (_) {
      return;
    }
  }

  Future<void> _sendPairedKeyEncryption(_ConnectionState connection) async {
    final frame = sn.Frame(
      version: sn.Frame_Version.V1,
      v1: sn.V1Frame(
        type: sn.V1Frame_FrameType.PAIRED_KEY_ENCRYPTION,
        pairedKeyEncryption: sn.PairedKeyEncryptionFrame(
          secretIdHash: randomBytes(6),
          signedData: randomBytes(72),
        ),
      ),
    );
    await _sendEncryptedSharingFrame(connection, frame);
  }

  Future<void> _handlePairedKeyEncryption(_ConnectionState connection) async {
    if (connection.sharingStage != _SharingStage.sentConnectionResponse &&
        connection.sharingStage !=
            _SharingStage.waitingForPairedKeyEncryption) {
      return;
    }

    final pairedResult = sn.Frame(
      version: sn.Frame_Version.V1,
      v1: sn.V1Frame(
        type: sn.V1Frame_FrameType.PAIRED_KEY_RESULT,
        pairedKeyResult: sn.PairedKeyResultFrame(
          status: sn.PairedKeyResultFrame_Status.UNABLE,
        ),
      ),
    );
    await _sendEncryptedSharingFrame(connection, pairedResult);
    connection.sharingStage = _SharingStage.sentPairedKeyResult;
  }

  Future<void> _handleIntroduction(
    _ConnectionState connection,
    sn.IntroductionFrame intro,
  ) async {
    if (intro.fileMetadata.isNotEmpty && intro.textMetadata.isEmpty) {
      final files = <String>[];
      var totalBytes = 0;
      for (final file in intro.fileMetadata) {
        files.add(file.name);
        totalBytes += file.size.toInt();
        connection.pendingPayloads[file.payloadId.toInt()] = file.name;
      }
      final existing = _active[connection.id];
      if (existing != null) {
        _emit(
          existing.copyWith(
            state: 'WaitingForUserConsent',
            files: files,
            totalBytes: totalBytes,
          ),
        );
      }
      await _sendSharingResponse(
        connection,
        sn.ConnectionResponseFrame_Status.ACCEPT,
      );
      return;
    }

    if (intro.textMetadata.length == 1) {
      final meta = intro.textMetadata.first;
      final existing = _active[connection.id];
      if (existing != null) {
        _emit(
          existing.copyWith(
            state: 'WaitingForUserConsent',
            transferType: meta.type.name,
            sourceName: existing.sourceName,
          ),
        );
      }
      connection.textPayloadId = meta.payloadId.toInt();
      connection.textType = meta.type.name;
      await _sendSharingResponse(
        connection,
        sn.ConnectionResponseFrame_Status.ACCEPT,
      );
      return;
    }

    if (intro.wifiCredentialsMetadata.length == 1) {
      final meta = intro.wifiCredentialsMetadata.first;
      final existing = _active[connection.id];
      if (existing != null) {
        _emit(
          existing.copyWith(
            state: 'WaitingForUserConsent',
            transferType: 'WIFI_CREDENTIALS',
          ),
        );
      }
      connection.textPayloadId = meta.payloadId.toInt();
      await _sendSharingResponse(
        connection,
        sn.ConnectionResponseFrame_Status.ACCEPT,
      );
      return;
    }

    await _sendSharingResponse(
      connection,
      sn.ConnectionResponseFrame_Status.UNSUPPORTED_ATTACHMENT_TYPE,
    );
  }

  Future<void> _sendSharingResponse(
    _ConnectionState connection,
    sn.ConnectionResponseFrame_Status status,
  ) async {
    _log('Sending sharing response $status to ${connection.id}');
    final response = sn.Frame(
      version: sn.Frame_Version.V1,
      v1: sn.V1Frame(
        type: sn.V1Frame_FrameType.RESPONSE,
        connectionResponse: sn.ConnectionResponseFrame(status: status),
      ),
    );
    await _sendEncryptedSharingFrame(connection, response);
  }

  Future<void> _sendEncryptedSharingFrame(
    _ConnectionState connection,
    sn.Frame frame,
  ) async {
    if (connection.encryptKey == null || connection.sendHmacKey == null) {
      _log(
        'Encrypted sharing frame skipped (keys missing) for ${connection.id}',
      );
      return;
    }
    final data = frame.writeToBuffer();
    final payloadId = _randomPayloadId();
    final header = lnc.PayloadTransferFrame_PayloadHeader(
      id: Int64(payloadId),
      type: lnc.PayloadTransferFrame_PayloadHeader_PayloadType.BYTES,
      totalSize: Int64(data.length),
      isSensitive: false,
    );

    final transfer = lnc.PayloadTransferFrame(
      packetType: lnc.PayloadTransferFrame_PacketType.DATA,
      payloadHeader: header,
      payloadChunk: lnc.PayloadTransferFrame_PayloadChunk(
        offset: Int64(0),
        flags: 0,
        body: data,
      ),
    );

    final wrapper = lnc.OfflineFrame(
      version: lnc.OfflineFrame_Version.V1,
      v1: lnc.V1Frame(
        type: lnc.V1Frame_FrameType.PAYLOAD_TRANSFER,
        payloadTransfer: transfer,
      ),
    );
    await _sendEncryptedOfflineFrame(connection, wrapper);

    final lastChunk = lnc.PayloadTransferFrame(
      packetType: lnc.PayloadTransferFrame_PacketType.DATA,
      payloadHeader: header,
      payloadChunk: lnc.PayloadTransferFrame_PayloadChunk(
        offset: Int64(data.length),
        flags: 1,
        body: const [],
      ),
    );
    final wrapperLast = lnc.OfflineFrame(
      version: lnc.OfflineFrame_Version.V1,
      v1: lnc.V1Frame(
        type: lnc.V1Frame_FrameType.PAYLOAD_TRANSFER,
        payloadTransfer: lastChunk,
      ),
    );
    await _sendEncryptedOfflineFrame(connection, wrapperLast);
    _log('Encrypted sharing frame sent to ${connection.id}');
  }

  Future<void> _sendEncryptedOfflineFrame(
    _ConnectionState connection,
    lnc.OfflineFrame frame,
  ) async {
    connection.serverSeq += 1;
    final seq = connection.serverSeq;
    final d2dMsg = d2d.DeviceToDeviceMessage(
      message: frame.writeToBuffer(),
      sequenceNumber: seq,
    );
    final d2dBytes = d2dMsg.writeToBuffer();

    final iv = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty).newNonce();
    final aes = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);
    final secretBox = await aes.encrypt(
      d2dBytes,
      secretKey: SecretKey(connection.encryptKey!),
      nonce: iv,
    );

    final metadata = gcm.GcmMetadata(
      type: gcm.Type.DEVICE_TO_DEVICE_MESSAGE,
      version: 1,
    );
    final header = sm.Header(
      signatureScheme: sm.SigScheme.HMAC_SHA256,
      encryptionScheme: sm.EncScheme.AES_256_CBC,
      iv: iv,
      publicMetadata: metadata.writeToBuffer(),
    );
    final headerAndBody = sm.HeaderAndBody(
      header: header,
      body: secretBox.cipherText,
    );
    final headerBytes = headerAndBody.writeToBuffer();
    final mac = await Hmac.sha256().calculateMac(
      headerBytes,
      secretKey: SecretKey(connection.sendHmacKey!),
    );
    final secure = sm.SecureMessage(
      headerAndBody: headerBytes,
      signature: mac.bytes,
    );
    await _sendFrame(connection.socket, secure.writeToBuffer());
  }

  Future<void> _sendDisconnection(_ConnectionState connection) async {
    final frame = lnc.OfflineFrame(
      version: lnc.OfflineFrame_Version.V1,
      v1: lnc.V1Frame(
        type: lnc.V1Frame_FrameType.DISCONNECTION,
        disconnection: lnc.DisconnectionFrame(),
      ),
    );

    if (connection.encryptKey != null && connection.sendHmacKey != null) {
      await _sendEncryptedOfflineFrame(connection, frame);
    } else {
      await _sendFrame(connection.socket, frame.writeToBuffer());
    }
    _log('Disconnection frame sent to ${connection.id}');
  }

  Future<void> _finishTransfer(_ConnectionState connection) async {
    if (connection.finished) {
      return;
    }
    connection.finished = true;
    final existing = _active[connection.id];
    if (existing != null) {
      _emit(
        existing.copyWith(state: 'Finished', ackBytes: existing.totalBytes),
      );
    }
    await _sendDisconnection(connection);
  }

  Future<void> _handleTextContent(
    _ConnectionState connection,
    Uint8List data,
  ) async {
    final text = utf8.decode(data, allowMalformed: true).trim();
    _log('Text content received type=${connection.textType}: "$text"');
    final existing = _active[connection.id];
    if (existing != null) {
      final isUrl = connection.textType == 'URL';
      _emit(
        existing.copyWith(
          state: 'Finished',
          url: isUrl ? text : null,
          ackBytes: existing.totalBytes > 0 ? existing.totalBytes : data.length,
          totalBytes: existing.totalBytes > 0 ? existing.totalBytes : data.length,
        ),
      );
    }
    connection.finished = true;
    await _sendDisconnection(connection);
  }

  int _randomPayloadId() {
    final rng = Random.secure();
    final hi = rng.nextInt(1 << 30);
    final lo = rng.nextInt(1 << 30);
    return (hi << 30) | lo;
  }

  Future<void> _handlePayloadTransfer(
    _ConnectionState connection,
    lnc.PayloadTransferFrame frame,
  ) async {
    if (!frame.hasPayloadHeader() && !frame.hasPayloadChunk()) {
      return;
    }

    int? currentId;
    if (frame.hasPayloadHeader()) {
      final header = frame.payloadHeader;
      if (header.type ==
          lnc.PayloadTransferFrame_PayloadHeader_PayloadType.FILE) {
        currentId = header.id.toInt();
        connection.lastPayloadId = currentId;
        if (currentId == connection.textPayloadId) {
          connection.bytesPayloads.putIfAbsent(
            currentId,
            () => _BytesPayload(
              id: currentId!,
              totalSize: header.totalSize.toInt(),
            ),
          );
          _log('Payload header TEXT id=$currentId size=${header.totalSize}');
        } else {
          await _registerFileTransfer(connection, header);
          _log('Payload header FILE id=$currentId size=${header.totalSize}');
        }
      } else if (header.type ==
          lnc.PayloadTransferFrame_PayloadHeader_PayloadType.BYTES) {
        currentId = header.id.toInt();
        final bytesId = currentId;
        connection.bytesPayloads.putIfAbsent(
          bytesId,
          () => _BytesPayload(id: bytesId, totalSize: header.totalSize.toInt()),
        );
        _log('Payload header BYTES id=$currentId size=${header.totalSize}');
      }
    }

    if (frame.hasPayloadChunk()) {
      await _handlePayloadChunk(
        connection,
        frame.payloadChunk,
        payloadId: currentId,
      );
    }
  }

  Future<void> _registerFileTransfer(
    _ConnectionState connection,
    lnc.PayloadTransferFrame_PayloadHeader header,
  ) async {
    final id = header.id.toInt();
    if (connection.files.containsKey(id)) {
      return;
    }

    await Directory(config.downloadDir).create(recursive: true);
    final filename = _sanitizeFilename(header.fileName);
    final outputPath = _uniquePath('${config.downloadDir}/$filename');
    final file = File(outputPath);
    final handle = await file.open(mode: FileMode.write);
    connection.files[id] = _InboundFile(
      id: id,
      fileName: pathBasename(outputPath),
      totalSize: header.totalSize.toInt(),
      handle: handle,
    );

    final existing = _active[connection.id];
    if (existing != null) {
      final files = [...existing.files];
      files.add(pathBasename(outputPath));
      final updatedTotal = existing.totalBytes == 0
          ? header.totalSize.toInt()
          : existing.totalBytes;
      _emit(
        existing.copyWith(
          state: existing.state == 'WaitingForUserConsent'
              ? 'ReceivingFiles'
              : existing.state,
          files: files,
          totalBytes: updatedTotal,
        ),
      );
    }
  }

  Future<void> _handlePayloadChunk(
    _ConnectionState connection,
    lnc.PayloadTransferFrame_PayloadChunk chunk, {
    int? payloadId,
  }) async {
    final id = payloadId ?? _lastPayloadId(connection);
    if (id == null) {
      _log('Payload chunk without id for ${connection.id}');
      return;
    }
    final info = connection.files[id];
    final bytesPayload = connection.bytesPayloads[id];
    if (info == null && bytesPayload == null) {
      _log(
        'Payload chunk for unknown id=$id offset=${chunk.offset} len=${chunk.body.length}',
      );
      return;
    }

    final offset = chunk.offset.toInt();
    if (info != null) {
      if (offset != info.bytesTransferred) {
        _log(
          'File chunk offset mismatch id=$id offset=$offset expected=${info.bytesTransferred}',
        );
        return;
      }
      if (chunk.body.isNotEmpty) {
        final chunkSize = chunk.body.length;
        final endOffset = offset + chunkSize;
        if (endOffset > info.totalSize) {
          _log(
            'File chunk exceeds size id=$id offset=$offset size=$chunkSize total=${info.totalSize}',
          );
          return;
        }
        try {
          await info.handle.setPosition(offset);
          await info.handle.writeFrom(chunk.body);
        } catch (e) {
          _log('File write failed id=$id offset=$offset size=$chunkSize: $e');
          return;
        }
        info.bytesTransferred += chunkSize;
        _updateProgress(connection, chunkSize);
        _log('File chunk id=$id offset=$offset bytes=$chunkSize');
      } else if ((chunk.flags & 1) == 1) {
        await info.handle.close();
        connection.files.remove(id);
        _log('File payload complete id=$id');
        if (connection.files.isEmpty) {
          await _finishTransfer(connection);
        }
      }
      return;
    }

    if (bytesPayload != null) {
      if (offset != bytesPayload.buffer.length) {
        _log(
          'Bytes chunk offset mismatch id=$id offset=$offset expected=${bytesPayload.buffer.length}',
        );
        return;
      }
      if (chunk.body.isNotEmpty) {
        bytesPayload.buffer.add(chunk.body);
        _log('Bytes chunk id=$id offset=$offset bytes=${chunk.body.length}');
      }
      if ((chunk.flags & 1) == 1) {
        final data = bytesPayload.buffer.toBytes();
        connection.bytesPayloads.remove(id);
        if (data.length == bytesPayload.totalSize) {
          if (id == connection.textPayloadId) {
            _log('Text payload complete id=$id size=${data.length}');
            await _handleTextContent(connection, data);
          } else {
            _log('Bytes payload complete id=$id size=${data.length}');
            await _handleSharingNearbyBytes(connection, data);
          }
        } else {
          _log(
            'Bytes payload size mismatch id=$id size=${data.length} expected=${bytesPayload.totalSize}',
          );
        }
      }
    }
  }

  void _updateProgress(_ConnectionState connection, int delta) {
    final existing = _active[connection.id];
    if (existing == null) {
      return;
    }
    _emit(existing.copyWith(ackBytes: existing.ackBytes + delta));
  }

  int? _lastPayloadId(_ConnectionState connection) {
    if (connection.lastPayloadId == null) {
      if (connection.files.isEmpty) {
        return null;
      }
      connection.lastPayloadId = connection.files.keys.first;
    }
    return connection.lastPayloadId;
  }

  String _sanitizeFilename(String name) {
    if (name.isEmpty) {
      return 'transfer.bin';
    }
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'transfer.bin' : cleaned;
  }

  String _uniquePath(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return path;
    }
    final dot = path.lastIndexOf('.');
    final base = dot == -1 ? path : path.substring(0, dot);
    final ext = dot == -1 ? '' : path.substring(dot);
    var index = 1;
    while (true) {
      final candidate = '$base ($index)$ext';
      if (!File(candidate).existsSync()) {
        return candidate;
      }
      index += 1;
    }
  }

  String pathBasename(String path) {
    final sep = Platform.pathSeparator;
    final index = path.lastIndexOf(sep);
    return index == -1 ? path : path.substring(index + 1);
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i += 1) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<bool> _handleUkey2Message(
    _ConnectionState connection,
    Uint8List frame,
  ) async {
    try {
      final msg = ukey.Ukey2Message.fromBuffer(frame);
      if (msg.messageType == ukey.Ukey2Message_Type.UNKNOWN_DO_NOT_USE ||
          msg.messageData.isEmpty) {
        return false;
      }
      _log('UKEY2 ${msg.messageType.name} from ${connection.id}');
      switch (msg.messageType) {
        case ukey.Ukey2Message_Type.CLIENT_INIT:
          await _handleUkeyClientInit(connection, msg, frame);
          return true;
        case ukey.Ukey2Message_Type.CLIENT_FINISH:
          await _handleUkeyClientFinish(connection, msg, frame);
          return true;
        case ukey.Ukey2Message_Type.ALERT:
          try {
            final alert = ukey.Ukey2Alert.fromBuffer(msg.messageData);
            _log(
              'UKEY2 ALERT type=${alert.type.name} msg=${alert.errorMessage}',
            );
          } catch (_) {
            _log('UKEY2 ALERT (failed to decode) from ${connection.id}');
          }
          return true;
        case ukey.Ukey2Message_Type.SERVER_INIT:
        case ukey.Ukey2Message_Type.UNKNOWN_DO_NOT_USE:
          return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleUkeyClientInit(
    _ConnectionState connection,
    ukey.Ukey2Message msg,
    Uint8List rawMsg,
  ) async {
    try {
      if (connection.stage != _HandshakeStage.awaitingClientInit) {
        await _sendUkeyAlert(
          connection,
          ukey.Ukey2Alert_AlertType.BAD_MESSAGE_TYPE,
        );
        return;
      }
      final clientInit = ukey.Ukey2ClientInit.fromBuffer(msg.messageData);
      _log(
        'UKEY2 ClientInit v=${clientInit.version} rand=${clientInit.random.length} next=${clientInit.nextProtocol}',
      );
      if (clientInit.version != 1) {
        await _sendUkeyAlert(connection, ukey.Ukey2Alert_AlertType.BAD_VERSION);
        return;
      }
      if (clientInit.random.length != 32) {
        await _sendUkeyAlert(connection, ukey.Ukey2Alert_AlertType.BAD_RANDOM);
        return;
      }

      var found = false;
      for (final commitment in clientInit.cipherCommitments) {
        if (commitment.handshakeCipher ==
            ukey.Ukey2HandshakeCipher.P256_SHA512) {
          connection.cipherCommitment = Uint8List.fromList(
            commitment.commitment,
          );
          found = true;
          break;
        }
      }
      if (!found) {
        _log('UKEY2 missing P256_SHA512');
        await _sendUkeyAlert(
          connection,
          ukey.Ukey2Alert_AlertType.BAD_HANDSHAKE_CIPHER,
        );
        return;
      }
      if (clientInit.nextProtocol != 'AES_256_CBC-HMAC_SHA256') {
        _log('UKEY2 bad nextProtocol ${clientInit.nextProtocol}');
        await _sendUkeyAlert(
          connection,
          ukey.Ukey2Alert_AlertType.BAD_NEXT_PROTOCOL,
        );
        return;
      }

      final keyPair = await NearbyCrypto.newKeyPair();
      _log(
        'UKEY2 pubkey x=${keyPair.publicX.length} y=${keyPair.publicY.length}',
      );
      final pkey = sm.GenericPublicKey(
        type: sm.PublicKeyType.EC_P256,
        ecP256PublicKey: sm.EcP256PublicKey(
          x: NearbyCrypto.encodePoint(keyPair.publicX),
          y: NearbyCrypto.encodePoint(keyPair.publicY),
        ),
      );

      final serverInit = ukey.Ukey2ServerInit(
        version: 1,
        random: randomBytes(32),
        handshakeCipher: ukey.Ukey2HandshakeCipher.P256_SHA512,
        publicKey: pkey.writeToBuffer(),
      );

      final serverMsg = ukey.Ukey2Message(
        messageType: ukey.Ukey2Message_Type.SERVER_INIT,
        messageData: serverInit.writeToBuffer(),
      );
      final serverMsgData = serverMsg.writeToBuffer();
      _log('UKEY2 ServerInit size=${serverMsgData.length}');
      await _sendFrame(connection.socket, serverMsgData);
      _log('UKEY2 ServerInit sent');

      connection.keyPair = keyPair;
      connection.clientInitData = Uint8List.fromList(rawMsg);
      connection.serverInitData = Uint8List.fromList(serverMsgData);
      connection.stage = _HandshakeStage.awaitingClientFinish;
      _log('Handshake -> awaitingClientFinish for ${connection.id}');
    } catch (e, st) {
      _log('UKEY2 ClientInit handler error: $e');
      _log('UKEY2 ClientInit handler stack: $st');
      return;
    }
  }

  Future<void> _handleUkeyClientFinish(
    _ConnectionState connection,
    ukey.Ukey2Message msg,
    Uint8List rawMsg,
  ) async {
    if (connection.stage != _HandshakeStage.awaitingClientFinish) {
      await _sendUkeyAlert(
        connection,
        ukey.Ukey2Alert_AlertType.BAD_MESSAGE_TYPE,
      );
      return;
    }
    final commitment = connection.cipherCommitment;
    if (commitment != null) {
      final hash = await Sha512().hash(rawMsg);
      if (!_constantTimeEquals(commitment, hash.bytes)) {
        _log('UKEY2 commitment mismatch for ${connection.id}');
        await _sendUkeyAlert(
          connection,
          ukey.Ukey2Alert_AlertType.BAD_MESSAGE_DATA,
        );
        return;
      }
    }
    final clientFinish = ukey.Ukey2ClientFinished.fromBuffer(msg.messageData);
    _log('UKEY2 ClientFinish received');
    if (clientFinish.publicKey.isEmpty) {
      await _sendUkeyAlert(
        connection,
        ukey.Ukey2Alert_AlertType.BAD_MESSAGE_DATA,
      );
      return;
    }
    final peerKey = sm.GenericPublicKey.fromBuffer(clientFinish.publicKey);
    if (!peerKey.hasEcP256PublicKey()) {
      await _sendUkeyAlert(
        connection,
        ukey.Ukey2Alert_AlertType.BAD_MESSAGE_DATA,
      );
      return;
    }
    await _finalizeKeyExchange(connection, peerKey);
    connection.stage = _HandshakeStage.awaitingConnectionResponse;
    _log('Handshake -> awaitingConnectionResponse for ${connection.id}');
    _maybeSendConnectionResponse(connection);
  }

  Future<void> _finalizeKeyExchange(
    _ConnectionState connection,
    sm.GenericPublicKey peerKey,
  ) async {
    final ec = peerKey.ecP256PublicKey;
    final x = NearbyCrypto.decodePointToFixed(ec.x, 32);
    final y = NearbyCrypto.decodePointToFixed(ec.y, 32);
    final keyPair = connection.keyPair;
    if (keyPair == null) {
      return;
    }

    final sharedSecret = await NearbyCrypto.sharedSecret(
      keyPair: keyPair,
      remoteX: x,
      remoteY: y,
    );
    final derivedSecret = await NearbyCrypto.sha256(sharedSecret);

    final ukeyInfo = BytesBuilder()
      ..add(connection.clientInitData ?? Uint8List(0))
      ..add(connection.serverInitData ?? Uint8List(0));

    final authString = await NearbyCrypto.hkdfExtractExpand(
      salt: 'UKEY2 v1 auth'.codeUnits,
      input: derivedSecret,
      info: ukeyInfo.toBytes(),
      outputLen: 32,
    );
    final nextSecret = await NearbyCrypto.hkdfExtractExpand(
      salt: 'UKEY2 v1 next'.codeUnits,
      input: derivedSecret,
      info: ukeyInfo.toBytes(),
      outputLen: 32,
    );

    final salt = hexToBytes(
      '82AA55A0D397F88346CA1CEE8D3909B95F13FA7DEB1D4AB38376B8256DA85510',
    );
    final d2dClient = await NearbyCrypto.hkdfExtractExpand(
      salt: salt,
      input: nextSecret,
      info: 'client'.codeUnits,
      outputLen: 32,
    );
    final d2dServer = await NearbyCrypto.hkdfExtractExpand(
      salt: salt,
      input: nextSecret,
      info: 'server'.codeUnits,
      outputLen: 32,
    );

    final keySalt = hexToBytes(
      'BF9D2A53C63616D75DB0A7165B91C1EF73E537F2427405FA23610A4BE657642E',
    );

    connection.decryptKey = await NearbyCrypto.hkdfExtractExpand(
      salt: keySalt,
      input: d2dClient,
      info: 'ENC:2'.codeUnits,
      outputLen: 32,
    );
    connection.recvHmacKey = await NearbyCrypto.hkdfExtractExpand(
      salt: keySalt,
      input: d2dClient,
      info: 'SIG:1'.codeUnits,
      outputLen: 32,
    );
    connection.encryptKey = await NearbyCrypto.hkdfExtractExpand(
      salt: keySalt,
      input: d2dServer,
      info: 'ENC:2'.codeUnits,
      outputLen: 32,
    );
    connection.sendHmacKey = await NearbyCrypto.hkdfExtractExpand(
      salt: keySalt,
      input: d2dServer,
      info: 'SIG:1'.codeUnits,
      outputLen: 32,
    );

    connection.authString = authString;
  }

  Future<void> _sendUkeyAlert(
    _ConnectionState connection,
    ukey.Ukey2Alert_AlertType type,
  ) async {
    final alert = ukey.Ukey2Alert(type: type);
    final msg = ukey.Ukey2Message(
      messageType: ukey.Ukey2Message_Type.ALERT,
      messageData: alert.writeToBuffer(),
    );
    await _sendFrame(connection.socket, msg.writeToBuffer());
  }

  void _log(String message) {
    if (_debug) {
      // ignore: avoid_print
      print('[RQS] $message');
    }
  }
}

class _ConnectionState {
  final String id;
  final Socket socket;
  bool sentResponse = false;
  _HandshakeStage stage = _HandshakeStage.awaitingConnectionRequest;
  bool? desiredResponse;
  bool receivedConnectionResponse = false;
  NearbyKeyPair? keyPair;
  Uint8List? clientInitData;
  Uint8List? serverInitData;
  Uint8List? cipherCommitment;
  Uint8List? decryptKey;
  Uint8List? encryptKey;
  Uint8List? recvHmacKey;
  Uint8List? sendHmacKey;
  Uint8List? authString;
  int expectedClientSeq = 0;
  int serverSeq = 0;
  Future<void> processing = Future.value();
  final Map<int, _InboundFile> files = {};
  int? lastPayloadId;
  final Map<int, String> pendingPayloads = {};
  int? textPayloadId;
  String? textType;
  final Map<int, _BytesPayload> bytesPayloads = {};
  _SharingStage sharingStage = _SharingStage.waitingForPairedKeyEncryption;
  bool finished = false;

  _ConnectionState({required this.id, required this.socket});
}

enum _SharingStage {
  waitingForPairedKeyEncryption,
  sentConnectionResponse,
  sentPairedKeyResult,
  receivedPairedKeyResult,
}

class _InboundFile {
  final int id;
  final String fileName;
  final int totalSize;
  final RandomAccessFile handle;
  int bytesTransferred = 0;
  bool warnedIncomplete = false;

  _InboundFile({
    required this.id,
    required this.fileName,
    required this.totalSize,
    required this.handle,
  });
}

class _BytesPayload {
  final int id;
  final int totalSize;
  final BytesBuilder buffer = BytesBuilder(copy: false);

  _BytesPayload({required this.id, required this.totalSize});
}

enum _HandshakeStage {
  awaitingConnectionRequest,
  awaitingClientInit,
  awaitingClientFinish,
  awaitingConnectionResponse,
  completed,
}
