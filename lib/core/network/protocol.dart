import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

const int kDiscoveryPort = 45454;
const int kTransferPort = 45455;
const int kProtocolVersion = 1;
const String kDiscoveryMagic = 'NexaDrop/1';
const int kEncryptedChunkSize = 256 * 1024;
const int kMaxFrameSize = 2 * 1024 * 1024;

class SocketByteReader {
  SocketByteReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  Uint8List _current = Uint8List(0);
  int _offset = 0;

  Future<Uint8List> readExactly(int length) async {
    if (length < 0) throw ArgumentError.value(length, 'length');
    if (length == 0) return Uint8List(0);

    final out = BytesBuilder(copy: false);
    var remaining = length;
    while (remaining > 0) {
      if (_offset >= _current.length) {
        final hasNext = await _iterator.moveNext();
        if (!hasNext) throw const SocketException('Connection closed unexpectedly.');
        _current = _iterator.current;
        _offset = 0;
      }
      final available = _current.length - _offset;
      final take = available < remaining ? available : remaining;
      out.add(Uint8List.sublistView(_current, _offset, _offset + take));
      _offset += take;
      remaining -= take;
    }
    return out.takeBytes();
  }

  Future<Uint8List> readFrame({int maxSize = kMaxFrameSize}) async {
    final header = await readExactly(4);
    final size = ByteData.sublistView(header).getUint32(0, Endian.big);
    if (size > maxSize) {
      throw FormatException('Frame too large: $size bytes.');
    }
    return readExactly(size);
  }

  Future<Map<String, dynamic>> readJsonFrame() async {
    final bytes = await readFrame();
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected JSON object frame.');
    }
    return value;
  }

  Future<void> cancel() => _iterator.cancel();
}

Future<void> writeFrame(Socket socket, List<int> payload) async {
  final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
  socket.add(header.buffer.asUint8List());
  socket.add(payload);
  await socket.flush();
}

Future<void> writeJsonFrame(Socket socket, Map<String, Object?> value) =>
    writeFrame(socket, utf8.encode(jsonEncode(value)));

Future<SecretKey> deriveSessionKey({
  required KeyPair localKeyPair,
  required SimplePublicKey remotePublicKey,
  required String transferId,
}) async {
  final shared = await X25519().sharedSecretKey(
    keyPair: localKeyPair,
    remotePublicKey: remotePublicKey,
  );
  try {
    return await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode(transferId),
      info: utf8.encode('NexaDrop encrypted transfer v1'),
    );
  } finally {
    shared.destroy();
  }
}

String pairingCode({
  required List<int> senderPublicKey,
  required List<int> receiverPublicKey,
  required String transferId,
}) {
  final digest = hash.sha256.convert([
    ...senderPublicKey,
    ...receiverPublicKey,
    ...utf8.encode(transferId),
  ]).bytes;
  final value = ((digest[0] << 16) | (digest[1] << 8) | digest[2]) % 1000000;
  return value.toString().padLeft(6, '0');
}

Uint8List _encodeEncryptedFrame(SecretBox box, int type) {
  if (box.nonce.length != 12) {
    throw StateError('AES-GCM nonce must be 12 bytes.');
  }
  if (box.mac.bytes.length != 16) {
    throw StateError('AES-GCM MAC must be 16 bytes.');
  }
  final result = Uint8List(1 + 12 + 16 + box.cipherText.length);
  result[0] = type;
  result.setRange(1, 13, box.nonce);
  result.setRange(13, 29, box.mac.bytes);
  result.setRange(29, result.length, box.cipherText);
  return result;
}

SecretBox _decodeEncryptedFrame(Uint8List frame, int expectedType) {
  if (frame.length < 29 || frame[0] != expectedType) {
    throw FormatException('Invalid encrypted frame type $expectedType.');
  }
  final nonce = Uint8List.sublistView(frame, 1, 13);
  final mac = Mac(Uint8List.sublistView(frame, 13, 29));
  final cipherText = Uint8List.sublistView(frame, 29);
  return SecretBox(cipherText, nonce: nonce, mac: mac);
}

Uint8List encodeEncryptedDataFrame(SecretBox box) => _encodeEncryptedFrame(box, 1);

SecretBox decodeEncryptedDataFrame(Uint8List frame) => _decodeEncryptedFrame(frame, 1);

Future<void> writeSecureJsonFrame(
  Socket socket,
  SecretKey sessionKey,
  Map<String, Object?> value,
) async {
  final clear = utf8.encode(jsonEncode(value));
  final box = await AesGcm.with256bits().encrypt(clear, secretKey: sessionKey);
  await writeFrame(socket, _encodeEncryptedFrame(box, 3));
}

Future<Map<String, dynamic>> readSecureJsonFrame(
  SocketByteReader reader,
  SecretKey sessionKey,
) async {
  final frame = await reader.readFrame();
  final box = _decodeEncryptedFrame(frame, 3);
  final clear = await AesGcm.with256bits().decrypt(box, secretKey: sessionKey);
  final value = jsonDecode(utf8.decode(clear));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid encrypted control JSON.');
  }
  return value;
}

Uint8List encodeControlFrame(Map<String, Object?> value) {
  final jsonBytes = utf8.encode(jsonEncode(value));
  final result = Uint8List(1 + jsonBytes.length)..[0] = 2;
  result.setRange(1, result.length, jsonBytes);
  return result;
}

Map<String, dynamic> decodeControlFrame(Uint8List frame) {
  if (frame.isEmpty || frame[0] != 2) {
    throw const FormatException('Invalid control frame.');
  }
  final value = jsonDecode(utf8.decode(frame.sublist(1)));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid control JSON.');
  }
  return value;
}

String sanitizeFileName(String input) {
  final replaced = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  if (replaced.isEmpty || replaced == '.' || replaced == '..') return 'received_file';
  return replaced.length <= 180 ? replaced : replaced.substring(replaced.length - 180);
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatSpeed(double bytesPerSecond) => '${formatBytes(bytesPerSecond.round())}/s';
