import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

import '../utils/crypto_utils.dart';

class NearbyKeyPair {
  final pc.ECPrivateKey privateKey;
  final pc.ECPublicKey publicKey;

  const NearbyKeyPair(this.privateKey, this.publicKey);

  Uint8List get publicX => _bigIntToFixed(publicKey.Q!.x!.toBigInteger()!, 32);
  Uint8List get publicY => _bigIntToFixed(publicKey.Q!.y!.toBigInteger()!, 32);
}

class NearbyCrypto {
  static final _params = pc.ECDomainParameters('prime256v1');

  static Future<NearbyKeyPair> newKeyPair() async {
    final keyGen = pc.ECKeyGenerator();
    keyGen.init(pc.ParametersWithRandom(
      pc.ECKeyGeneratorParameters(_params),
      _secureRandom(),
    ));
    final pair = keyGen.generateKeyPair();
    final publicKey = pair.publicKey as pc.ECPublicKey;
    final privateKey = pair.privateKey as pc.ECPrivateKey;
    return NearbyKeyPair(privateKey, publicKey);
  }

  static Uint8List encodePoint(List<int> unsigned) {
    return encodeSignedBytes(Uint8List.fromList(unsigned));
  }

  static Uint8List decodePointToFixed(List<int> signed, int length) {
    return decodeSignedBytesToFixed(Uint8List.fromList(signed), length);
  }

  static Future<Uint8List> sha256(List<int> data) async {
    final hash = await Sha256().hash(data);
    return Uint8List.fromList(hash.bytes);
  }

  static Future<Uint8List> hkdfExtractExpand({
    required List<int> salt,
    required List<int> input,
    required List<int> info,
    required int outputLen,
  }) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: outputLen);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(input),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<Uint8List> sharedSecret({
    required NearbyKeyPair keyPair,
    required Uint8List remoteX,
    required Uint8List remoteY,
  }) async {
    final remote = _publicKeyFromXY(remoteX, remoteY);
    final agreement = pc.ECDHBasicAgreement();
    agreement.init(keyPair.privateKey);
    final secret = agreement.calculateAgreement(remote);
    return _bigIntToFixed(secret, 32);
  }

  static pc.ECPublicKey _publicKeyFromXY(Uint8List x, Uint8List y) {
    final point = _params.curve.createPoint(_bytesToBigInt(x), _bytesToBigInt(y));
    return pc.ECPublicKey(point, _params);
  }

  static pc.SecureRandom _secureRandom() {
    final random = pc.FortunaRandom();
    final seed = Uint8List(32);
    final source = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = source.nextInt(256);
    }
    random.seed(pc.KeyParameter(seed));
    return random;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }
}

Uint8List _bigIntToFixed(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}
