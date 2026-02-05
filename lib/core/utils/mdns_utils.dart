import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../models/device_type.dart';

String _base64UrlNoPadEncode(Uint8List bytes) {
  final encoded = base64Url.encode(bytes);
  return encoded.replaceAll('=', '');
}

Uint8List _base64UrlNoPadDecode(String input) {
  final pad = (4 - input.length % 4) % 4;
  final padded = input + ('=' * pad);
  return base64Url.decode(padded);
}

Uint8List randomBytes(int length) {
  final rng = Random.secure();
  final data = Uint8List(length);
  for (var i = 0; i < length; i += 1) {
    data[i] = rng.nextInt(256);
  }
  return data;
}

String genMdnsName(Uint8List endpointId) {
  if (endpointId.length != 4) {
    throw ArgumentError('endpointId must be 4 bytes');
  }
  final buffer = BytesBuilder();
  buffer.add([0x23]);
  buffer.add(endpointId);
  buffer.add([0xFC, 0x9F, 0x5E]);
  buffer.add([0x00, 0x00]);
  return _base64UrlNoPadEncode(buffer.toBytes());
}

String genMdnsEndpointInfo(DeviceType deviceType, String deviceName) {
  final buffer = BytesBuilder();
  final rawType = deviceType.index & 0x7;
  buffer.add([rawType << 1]);
  buffer.add(randomBytes(16));
  final nameBytes = utf8.encode(deviceName);
  final length = nameBytes.length > 255 ? 255 : nameBytes.length;
  buffer.add([length]);
  buffer.add(nameBytes.take(length).toList());
  return _base64UrlNoPadEncode(buffer.toBytes());
}

({DeviceType deviceType, String name}) parseMdnsEndpointInfo(String encoded) {
  final decoded = _base64UrlNoPadDecode(encoded);
  if (decoded.length < 19) {
    throw FormatException('Invalid endpoint info length');
  }
  return parseEndpointInfoBytes(decoded);
}

({DeviceType deviceType, String name}) parseEndpointInfoBytes(Uint8List decoded) {
  if (decoded.length < 19) {
    throw FormatException('Invalid endpoint info length');
  }
  final rawType = (decoded[0] >> 1) & 0x7;
  final nameLength = decoded[17];
  if (18 + nameLength > decoded.length) {
    throw FormatException('Invalid endpoint name length');
  }
  final nameBytes = decoded.sublist(18, 18 + nameLength);
  final name = utf8.decode(nameBytes, allowMalformed: false);
  return (deviceType: deviceTypeFromRaw(rawType), name: name);
}
