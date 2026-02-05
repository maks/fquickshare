import 'dart:typed_data';

Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s+'), '');
  if (clean.length % 2 != 0) {
    throw FormatException('Invalid hex length');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < clean.length; i += 2) {
    out[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
  }
  return out;
}

Uint8List encodeSignedBytes(Uint8List unsigned) {
  var start = 0;
  while (start < unsigned.length && unsigned[start] == 0) {
    start += 1;
  }
  final trimmed = unsigned.sublist(start);
  if (trimmed.isEmpty) {
    return Uint8List.fromList([0]);
  }
  if (trimmed[0] & 0x80 != 0) {
    final out = Uint8List(trimmed.length + 1);
    out[0] = 0;
    out.setRange(1, out.length, trimmed);
    return out;
  }
  return Uint8List.fromList(trimmed);
}

Uint8List decodeSignedBytesToFixed(Uint8List signed, int length) {
  var start = 0;
  while (start < signed.length - 1 && signed[start] == 0) {
    start += 1;
  }
  final trimmed = signed.sublist(start);
  if (trimmed.length == length) {
    return Uint8List.fromList(trimmed);
  }
  if (trimmed.length > length) {
    return Uint8List.fromList(trimmed.sublist(trimmed.length - length));
  }
  final out = Uint8List(length);
  out.setRange(length - trimmed.length, length, trimmed);
  return out;
}
