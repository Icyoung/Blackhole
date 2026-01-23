import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class CryptoService {
  CryptoService();

  SimpleKeyPair? _keyPair;
  SecretKey? _sharedSecret;
  int _sendNonce = 0;
  int _recvNonce = 0;

  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  bool get hasKeyPair => _keyPair != null;
  bool get hasSharedSecret => _sharedSecret != null;

  Future<void> generateKeyPair() async {
    _keyPair = await _x25519.newKeyPair();
  }

  Future<void> loadKeyPair({
    required String publicKeyBase64,
    required String privateKeyBase64,
  }) async {
    final publicKeyBytes = base64Decode(publicKeyBase64);
    final privateKeyBytes = base64Decode(privateKeyBase64);

    final publicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);

    _keyPair = SimpleKeyPairData(
      privateKeyBytes,
      publicKey: publicKey,
      type: KeyPairType.x25519,
    );
  }

  Future<String> getPublicKeyBase64() async {
    final keyPair = _keyPair;
    if (keyPair == null) {
      throw StateError('No key pair generated');
    }
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  Future<String> getPrivateKeyBase64() async {
    final keyPair = _keyPair;
    if (keyPair == null) {
      throw StateError('No key pair generated');
    }
    final privateKey = await keyPair.extractPrivateKeyBytes();
    return base64Encode(privateKey);
  }

  String getPublicKeyFingerprint(String publicKeyBase64) {
    final bytes = base64Decode(publicKeyBase64);
    final fingerprint = bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    return fingerprint;
  }

  Future<void> computeSharedSecret(String remotePublicKeyBase64) async {
    final keyPair = _keyPair;
    if (keyPair == null) {
      throw StateError('No key pair generated');
    }

    final remotePublicKeyBytes = base64Decode(remotePublicKeyBase64);
    final remotePublicKey = SimplePublicKey(
      remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecretResult = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );

    final derivedKey = await _hkdf.deriveKey(
      secretKey: sharedSecretResult,
      info: utf8.encode('blackhole-e2e-v1'),
      nonce: Uint8List(0),
    );

    _sharedSecret = derivedKey;
    _sendNonce = 0;
    _recvNonce = 0;
  }

  void loadSharedSecret(String sharedSecretBase64) {
    final bytes = base64Decode(sharedSecretBase64);
    _sharedSecret = SecretKeyData(bytes);
    _sendNonce = 0;
    _recvNonce = 0;
  }

  Future<String> getSharedSecretBase64() async {
    final secret = _sharedSecret;
    if (secret == null) {
      throw StateError('No shared secret computed');
    }
    final bytes = await secret.extractBytes();
    return base64Encode(bytes);
  }

  Uint8List _buildNonce(int counter) {
    final nonce = Uint8List(12);
    nonce[8] = (counter >> 24) & 0xFF;
    nonce[9] = (counter >> 16) & 0xFF;
    nonce[10] = (counter >> 8) & 0xFF;
    nonce[11] = counter & 0xFF;
    return nonce;
  }

  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final secret = _sharedSecret;
    if (secret == null) {
      throw StateError('No shared secret computed');
    }

    final nonce = _buildNonce(_sendNonce);
    _sendNonce++;

    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: secret,
      nonce: nonce,
    );

    final result = BytesBuilder(copy: false)
      ..add(nonce)
      ..add(secretBox.cipherText)
      ..add(secretBox.mac.bytes);
    return result.toBytes();
  }

  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    final secret = _sharedSecret;
    if (secret == null) {
      throw StateError('No shared secret computed');
    }

    if (ciphertext.length < 12 + 16) {
      throw ArgumentError('Ciphertext too short');
    }

    final nonce = ciphertext.sublist(0, 12);
    final encrypted = ciphertext.sublist(12, ciphertext.length - 16);
    final mac = Mac(ciphertext.sublist(ciphertext.length - 16));

    final secretBox = SecretBox(encrypted, nonce: nonce, mac: mac);
    final plaintext = await _aesGcm.decrypt(secretBox, secretKey: secret);

    _recvNonce++;
    return Uint8List.fromList(plaintext);
  }

  Future<String> encryptJson(Map<String, dynamic> payload) async {
    final jsonStr = jsonEncode(payload);
    final plaintext = Uint8List.fromList(utf8.encode(jsonStr));
    final encrypted = await encrypt(plaintext);
    return base64Encode(encrypted);
  }

  Future<Map<String, dynamic>> decryptJson(String encryptedBase64) async {
    final ciphertext = base64Decode(encryptedBase64);
    final plaintext = await decrypt(ciphertext);
    final jsonStr = utf8.decode(plaintext);
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  void resetNonces() {
    _sendNonce = 0;
    _recvNonce = 0;
  }

  void clear() {
    _sharedSecret = null;
    _sendNonce = 0;
    _recvNonce = 0;
  }
}
