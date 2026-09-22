import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:saf/saf.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import 'protocol.dart';

const int _maxSingleFileBytes = 10 * 1024 * 1024 * 1024 * 1024;
const int _maxBatchFiles = 1000;

class TransferService {
  TransferService(this.identity);

  AppIdentity identity;
  ServerSocket? _server;

  final StreamController<IncomingConnectionRequest> _connectionController =
      StreamController<IncomingConnectionRequest>.broadcast();
  final StreamController<IncomingTransferRequest> _incomingController =
      StreamController<IncomingTransferRequest>.broadcast();
  final StreamController<TransferActivity> _activityController =
      StreamController<TransferActivity>.broadcast();

  final Map<String, Completer<bool>> _pendingConnections = {};
  final Map<String, _PendingIncomingTransfer> _pendingTransfers = {};
  final Map<String, TransferActivity> _activities = {};

  Stream<IncomingConnectionRequest> get incomingConnections =>
      _connectionController.stream;
  Stream<IncomingTransferRequest> get incomingRequests =>
      _incomingController.stream;
  Stream<TransferActivity> get activityUpdates => _activityController.stream;

  List<TransferActivity> get activities => _activities.values.toList()
    ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  void updateIdentity(AppIdentity value) {
    identity = value;
  }

  Future<void> start() async {
    if (_server != null) return;
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, kTransferPort);
    _server!.listen(
      (socket) => unawaited(_handleIncomingSocket(socket)),
      onError: (_) {},
    );
  }

  Future<OutgoingTransferSession?> requestConnection(
    NearbyDevice device, {
    void Function(String pairingCode)? onPairingCode,
  }) async {
    final sessionId = const Uuid().v4();
    Socket? socket;
    SocketByteReader? reader;
    SimpleKeyPair? senderKeyPair;
    try {
      socket = await Socket.connect(
        device.address,
        device.port,
        timeout: const Duration(seconds: 8),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = SocketByteReader(socket);

      senderKeyPair = await X25519().newKeyPair();
      final senderPublic = await senderKeyPair.extractPublicKey();
      await writeJsonFrame(socket, {
        'type': 'connect_offer',
        'version': kProtocolVersion,
        'sessionId': sessionId,
        'senderId': identity.id,
        'senderName': identity.name,
        'senderPlatform': identity.platformLabel,
        'senderPublicKey': base64Encode(senderPublic.bytes),
      });

      final challenge = await reader
          .readJsonFrame()
          .timeout(const Duration(seconds: 12));
      if (challenge['type'] != 'connect_challenge') {
        throw const FormatException('Unexpected connection challenge.');
      }
      final receiverBytes =
          base64Decode(challenge['receiverPublicKey'] as String);
      final receiverPublic =
          SimplePublicKey(receiverBytes, type: KeyPairType.x25519);
      final code = pairingCode(
        senderPublicKey: senderPublic.bytes,
        receiverPublicKey: receiverBytes,
        transferId: sessionId,
      );
      onPairingCode?.call(code);

      final response = await reader
          .readJsonFrame()
          .timeout(const Duration(minutes: 2));
      if (response['type'] != 'connect_response' || response['accepted'] != true) {
        await reader.cancel();
        socket.destroy();
        return null;
      }

      final sessionKey = await deriveSessionKey(
        localKeyPair: senderKeyPair,
        remotePublicKey: receiverPublic,
        transferId: sessionId,
      );
      senderKeyPair.destroy();
      senderKeyPair = null;

      return OutgoingTransferSession._(
        service: this,
        sessionId: sessionId,
        device: device,
        pairingCode: code,
        socket: socket,
        reader: reader,
        sessionKey: sessionKey,
      );
    } on Object {
      senderKeyPair?.destroy();
      await reader?.cancel();
      socket?.destroy();
      return null;
    }
  }

  Future<void> acceptConnection(String requestId) async {
    final pending = _pendingConnections[requestId];
    if (pending != null && !pending.isCompleted) pending.complete(true);
  }

  Future<void> rejectConnection(String requestId) async {
    final pending = _pendingConnections[requestId];
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  Future<void> acceptIncoming(String requestId, ReceiveTarget target) async {
    final pending = _pendingTransfers[requestId];
    if (pending == null || pending.decision.isCompleted) return;
    pending.decision.complete(_IncomingDecision.accept(target));
  }

  Future<void> rejectIncoming(String requestId) async {
    final pending = _pendingTransfers[requestId];
    if (pending == null || pending.decision.isCompleted) return;
    pending.decision.complete(const _IncomingDecision.reject());
  }

  Future<void> _handleIncomingSocket(Socket socket) async {
    final reader = SocketByteReader(socket);
    SimpleKeyPair? receiverKeyPair;
    SecretKey? sessionKey;
    String? sessionId;
    var challengeSent = false;
    var connectionAccepted = false;

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      final offer = await reader
          .readJsonFrame()
          .timeout(const Duration(seconds: 10));
      if (offer['type'] != 'connect_offer' ||
          offer['version'] != kProtocolVersion) {
        throw const FormatException('Unsupported connection request.');
      }

      sessionId = offer['sessionId'] as String;
      final senderName = offer['senderName'] as String? ?? 'Nearby device';
      final senderPlatform = offer['senderPlatform'] as String? ?? 'Device';
      final senderPublicBytes =
          base64Decode(offer['senderPublicKey'] as String);
      if (senderPublicBytes.length != 32) {
        throw const FormatException('Invalid sender public key.');
      }
      final senderPublic =
          SimplePublicKey(senderPublicBytes, type: KeyPairType.x25519);

      receiverKeyPair = await X25519().newKeyPair();
      final receiverPublic = await receiverKeyPair.extractPublicKey();
      final code = pairingCode(
        senderPublicKey: senderPublicBytes,
        receiverPublicKey: receiverPublic.bytes,
        transferId: sessionId,
      );

      await writeJsonFrame(socket, {
        'type': 'connect_challenge',
        'receiverPublicKey': base64Encode(receiverPublic.bytes),
      });
      challengeSent = true;

      final connectionDecision = Completer<bool>();
      _pendingConnections[sessionId] = connectionDecision;
      _connectionController.add(IncomingConnectionRequest(
        id: sessionId,
        senderName: senderName,
        senderPlatform: senderPlatform,
        pairingCode: code,
      ));

      final accepted = await connectionDecision.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => false,
      );
      _pendingConnections.remove(sessionId);

      await writeJsonFrame(socket, {
        'type': 'connect_response',
        'accepted': accepted,
      });
      if (!accepted) return;
      connectionAccepted = true;

      sessionKey = await deriveSessionKey(
        localKeyPair: receiverKeyPair,
        remotePublicKey: senderPublic,
        transferId: sessionId,
      );
      receiverKeyPair.destroy();
      receiverKeyPair = null;

      await _receiveAuthorizedSession(
        socket: socket,
        reader: reader,
        sessionKey: sessionKey,
        sessionId: sessionId,
        senderName: senderName,
        senderPlatform: senderPlatform,
        pairingCode: code,
      );
    } on Object catch (error) {
      if (challengeSent && !connectionAccepted) {
        try {
          await writeJsonFrame(socket, {
            'type': 'connect_response',
            'accepted': false,
            'message': error.toString(),
          });
        } on Object {
          // Peer may have already disconnected.
        }
      } else if (connectionAccepted && sessionKey != null) {
        try {
          await writeSecureJsonFrame(socket, sessionKey, {
            'type': 'session_error',
            'message': error.toString(),
          });
        } on Object {
          // Peer may have already disconnected.
        }
      }
    } finally {
      if (sessionId != null) {
        _pendingConnections.remove(sessionId);
        final pending = _pendingTransfers.remove(sessionId);
        if (pending != null && !pending.decision.isCompleted) {
          pending.decision.complete(const _IncomingDecision.reject());
        }
      }
      sessionKey?.destroy();
      receiverKeyPair?.destroy();
      await reader.cancel();
      socket.destroy();
    }
  }

  Future<void> _receiveAuthorizedSession({
    required Socket socket,
    required SocketByteReader reader,
    required SecretKey sessionKey,
    required String sessionId,
    required String senderName,
    required String senderPlatform,
    required String pairingCode,
  }) async {
    final first = await readSecureJsonFrame(reader, sessionKey)
        .timeout(const Duration(minutes: 3));
    if (first['type'] == 'session_close') return;
    if (first['type'] != 'batch_offer') {
      throw const FormatException('Expected an encrypted batch offer.');
    }

    final rawFiles = first['files'];
    if (rawFiles is! List || rawFiles.isEmpty || rawFiles.length > _maxBatchFiles) {
      throw const FormatException('Invalid transfer file list.');
    }

    final files = <IncomingFileInfo>[];
    for (final item in rawFiles) {
      if (item is! Map) throw const FormatException('Invalid file descriptor.');
      final nameValue = item['name'];
      final sizeValue = item['size'];
      if (nameValue is! String || sizeValue is! int) {
        throw const FormatException('Invalid file descriptor values.');
      }
      final safeName = sanitizeFileName(nameValue);
      if (sizeValue < 0 || sizeValue > _maxSingleFileBytes) {
        throw const FormatException('Invalid file size.');
      }
      files.add(IncomingFileInfo(name: safeName, size: sizeValue));
    }

    final request = IncomingTransferRequest(
      id: sessionId,
      files: List.unmodifiable(files),
      senderName: senderName,
      senderPlatform: senderPlatform,
      pairingCode: pairingCode,
    );
    final pending = _PendingIncomingTransfer(
      request: request,
      decision: Completer<_IncomingDecision>(),
    );
    _pendingTransfers[sessionId] = pending;

    for (var i = 0; i < files.length; i++) {
      final info = files[i];
      _setActivity(TransferActivity(
        id: _fileActivityId(sessionId, i),
        fileName: info.name,
        fileSize: info.size,
        direction: TransferDirection.received,
        status: TransferStatus.waiting,
        peerName: senderName,
        startedAt: DateTime.now(),
        pairingCode: pairingCode,
      ));
    }
    _incomingController.add(request);

    final decision = await pending.decision.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () => const _IncomingDecision.reject(),
    );
    _pendingTransfers.remove(sessionId);

    if (!decision.accepted || decision.target == null) {
      await writeSecureJsonFrame(socket, sessionKey, {
        'type': 'batch_response',
        'accepted': false,
      });
      for (var i = 0; i < files.length; i++) {
        _updateActivity(
          _fileActivityId(sessionId, i),
          status: TransferStatus.rejected,
        );
      }
      return;
    }

    await writeSecureJsonFrame(socket, sessionKey, {
      'type': 'batch_response',
      'accepted': true,
    });

    for (var i = 0; i < files.length; i++) {
      final expected = files[i];
      final activityId = _fileActivityId(sessionId, i);
      final start = await readSecureJsonFrame(reader, sessionKey);
      if (start['type'] != 'file_start' ||
          start['index'] != i ||
          sanitizeFileName(start['name'] as String? ?? '') != expected.name ||
          start['size'] != expected.size) {
        throw const FormatException('File metadata changed after approval.');
      }

      _updateActivity(activityId, status: TransferStatus.transferring);
      final receiver = _IncomingPlaintextStream(
        reader: reader,
        sessionKey: sessionKey,
        fileSize: expected.size,
        onProgress: (bytes, speed) => _updateActivity(
          activityId,
          bytesDone: bytes,
          bytesPerSecond: speed,
        ),
      );

      try {
        await _writeIncomingFile(
          decision.target!,
          expected.name,
          receiver.stream(),
        );
        if (!receiver.verified) {
          throw const StateError('Encrypted stream did not finish verification.');
        }
        await writeSecureJsonFrame(socket, sessionKey, {
          'type': 'file_ack',
          'index': i,
          'ok': true,
        });
        _updateActivity(
          activityId,
          status: TransferStatus.completed,
          bytesDone: expected.size,
        );
      } on Object catch (error) {
        _updateActivity(
          activityId,
          status: TransferStatus.failed,
          error: error.toString(),
        );
        try {
          await writeSecureJsonFrame(socket, sessionKey, {
            'type': 'file_ack',
            'index': i,
            'ok': false,
            'message': error.toString(),
          });
        } on Object {
          // Ignore secondary connection failure.
        }
        rethrow;
      }
    }

    final completed = await readSecureJsonFrame(reader, sessionKey);
    if (completed['type'] != 'batch_complete') {
      throw const FormatException('Missing batch completion frame.');
    }
    await writeSecureJsonFrame(socket, sessionKey, {
      'type': 'batch_ack',
      'ok': true,
    });
  }

  Future<void> _writeIncomingFile(
    ReceiveTarget target,
    String fileName,
    Stream<List<int>> source,
  ) async {
    if (target.type == ReceiveTargetType.androidSaf) {
      final saf = Saf();
      final uniqueName = await _uniqueSafName(saf, target.value, fileName);
      await saf.writeFileStream(
        target.value,
        uniqueName,
        _mimeTypeFor(uniqueName),
        source,
        overwrite: false,
      );
      return;
    }

    final output = await _uniqueFileInDirectory(target.value, fileName);
    final sink = output.openWrite();
    try {
      await sink.addStream(source);
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close();
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  Future<String> _uniqueSafName(
    Saf saf,
    String dirUri,
    String fileName,
  ) async {
    if (await saf.child(dirUri, [fileName]) == null) return fileName;
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; i <= 9999; i++) {
      final candidate = '$base ($i)$ext';
      if (await saf.child(dirUri, [candidate]) == null) return candidate;
    }
    return '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }

  Future<File> _uniqueFileInDirectory(
    String directory,
    String fileName,
  ) async {
    final separator = Platform.pathSeparator;
    final root = directory.endsWith(separator)
        ? directory.substring(0, directory.length - 1)
        : directory;
    File candidate = File('$root$separator$fileName');
    if (!await candidate.exists()) return candidate;
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; i <= 9999; i++) {
      candidate = File('$root$separator$base ($i)$ext');
      if (!await candidate.exists()) return candidate;
    }
    return File(
      '$root$separator${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
  }

  String _mimeTypeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      'mp4' => 'video/mp4',
      'mp3' => 'audio/mpeg',
      _ => 'application/octet-stream',
    };
  }

  String _fileActivityId(String sessionId, int index) => '$sessionId:$index';

  void _setActivity(TransferActivity activity) {
    _activities[activity.id] = activity;
    _activityController.add(activity);
  }

  void _updateActivity(
    String id, {
    TransferStatus? status,
    int? bytesDone,
    double? bytesPerSecond,
    String? pairingCode,
    String? error,
  }) {
    final current = _activities[id];
    if (current == null) return;
    _setActivity(current.copyWith(
      status: status,
      bytesDone: bytesDone,
      bytesPerSecond: bytesPerSecond,
      pairingCode: pairingCode,
      error: error,
    ));
  }

  Future<void> dispose() async {
    await _server?.close();
    for (final pending in _pendingConnections.values) {
      if (!pending.isCompleted) pending.complete(false);
    }
    for (final pending in _pendingTransfers.values) {
      if (!pending.decision.isCompleted) {
        pending.decision.complete(const _IncomingDecision.reject());
      }
    }
    _pendingConnections.clear();
    _pendingTransfers.clear();
    await _connectionController.close();
    await _incomingController.close();
    await _activityController.close();
  }
}

class OutgoingTransferSession {
  OutgoingTransferSession._({
    required this.service,
    required this.sessionId,
    required this.device,
    required this.pairingCode,
    required this.socket,
    required this.reader,
    required this.sessionKey,
  });

  final TransferService service;
  final String sessionId;
  final NearbyDevice device;
  final String pairingCode;
  final Socket socket;
  final SocketByteReader reader;
  final SecretKey sessionKey;
  bool _closed = false;

  Future<bool> sendFiles(List<PlatformFile> selectedFiles) async {
    if (_closed) throw StateError('Transfer session is already closed.');
    if (selectedFiles.isEmpty) return true;
    if (selectedFiles.length > _maxBatchFiles) {
      throw StateError('A batch can contain at most $_maxBatchFiles files.');
    }

    final files = <_OutgoingFile>[];
    for (final file in selectedFiles) {
      final length = file.lengthSync() ?? await file.length();
      if (length == null) {
        throw StateError('Could not determine the size of ${file.name}.');
      }
      if (length < 0 || length > _maxSingleFileBytes) {
        throw StateError('${file.name} has an unsupported size.');
      }
      files.add(_OutgoingFile(file, sanitizeFileName(file.name), length));
    }

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      service._setActivity(TransferActivity(
        id: service._fileActivityId(sessionId, i),
        fileName: file.name,
        fileSize: file.size,
        direction: TransferDirection.sent,
        status: TransferStatus.waiting,
        peerName: device.name,
        startedAt: DateTime.now(),
        pairingCode: pairingCode,
      ));
    }

    try {
      await writeSecureJsonFrame(socket, sessionKey, {
        'type': 'batch_offer',
        'files': files
            .map((file) => <String, Object>{
                  'name': file.name,
                  'size': file.size,
                })
            .toList(),
      });

      final response = await readSecureJsonFrame(reader, sessionKey)
          .timeout(const Duration(minutes: 3));
      if (response['type'] == 'session_error') {
        throw StateError(response['message'] as String? ?? 'Receiver error.');
      }
      if (response['type'] != 'batch_response') {
        throw const FormatException('Unexpected batch response.');
      }
      if (response['accepted'] != true) {
        for (var i = 0; i < files.length; i++) {
          service._updateActivity(
            service._fileActivityId(sessionId, i),
            status: TransferStatus.rejected,
            error: 'Receiver declined the transfer.',
          );
        }
        return false;
      }

      for (var i = 0; i < files.length; i++) {
        await _sendOne(files[i], i);
      }

      await writeSecureJsonFrame(socket, sessionKey, {
        'type': 'batch_complete',
      });
      final ack = await readSecureJsonFrame(reader, sessionKey)
          .timeout(const Duration(seconds: 20));
      if (ack['type'] != 'batch_ack' || ack['ok'] != true) {
        throw StateError(ack['message'] as String? ?? 'Receiver did not confirm the batch.');
      }
      return true;
    } on Object catch (error) {
      for (var i = 0; i < files.length; i++) {
        final id = service._fileActivityId(sessionId, i);
        final activity = service._activities[id];
        if (activity != null &&
            activity.status != TransferStatus.completed &&
            activity.status != TransferStatus.rejected) {
          service._updateActivity(
            id,
            status: TransferStatus.failed,
            error: error.toString(),
          );
        }
      }
      return false;
    }
  }

  Future<void> _sendOne(_OutgoingFile file, int index) async {
    final activityId = service._fileActivityId(sessionId, index);
    await writeSecureJsonFrame(socket, sessionKey, {
      'type': 'file_start',
      'index': index,
      'name': file.name,
      'size': file.size,
    });
    service._updateActivity(
      activityId,
      status: TransferStatus.transferring,
    );

    final cipher = AesGcm.with256bits();
    final digestSink = _DigestCollector();
    final hashInput = hash.sha256.startChunkedConversion(digestSink);
    var sent = 0;
    final watch = Stopwatch()..start();

    await for (final raw in file.source.readAsByteStream()) {
      var offset = 0;
      while (offset < raw.length) {
        final end = (offset + kEncryptedChunkSize < raw.length)
            ? offset + kEncryptedChunkSize
            : raw.length;
        final clear = Uint8List.sublistView(raw, offset, end);
        hashInput.add(clear);
        final box = await cipher.encrypt(clear, secretKey: sessionKey);
        await writeFrame(socket, encodeEncryptedDataFrame(box));
        sent += clear.length;
        offset = end;
        final seconds = watch.elapsedMicroseconds / 1000000.0;
        service._updateActivity(
          activityId,
          bytesDone: sent,
          bytesPerSecond: seconds <= 0 ? 0 : sent / seconds,
        );
      }
    }
    hashInput.close();

    if (sent != file.size) {
      throw StateError('Read $sent bytes from ${file.name}, expected ${file.size}.');
    }

    await writeSecureJsonFrame(socket, sessionKey, {
      'type': 'file_complete',
      'index': index,
      'bytes': sent,
      'sha256': digestSink.digestHex,
    });
    final ack = await readSecureJsonFrame(reader, sessionKey)
        .timeout(const Duration(seconds: 30));
    if (ack['type'] == 'session_error') {
      throw StateError(ack['message'] as String? ?? 'Receiver error.');
    }
    if (ack['type'] != 'file_ack' || ack['index'] != index || ack['ok'] != true) {
      throw StateError(ack['message'] as String? ?? 'Receiver could not verify ${file.name}.');
    }

    service._updateActivity(
      activityId,
      status: TransferStatus.completed,
      bytesDone: file.size,
    );
  }

  Future<void> close({bool notifyPeer = true}) async {
    if (_closed) return;
    _closed = true;
    if (notifyPeer) {
      try {
        await writeSecureJsonFrame(socket, sessionKey, {
          'type': 'session_close',
        });
      } on Object {
        // Socket may already be closed after a completed batch.
      }
    }
    sessionKey.destroy();
    await reader.cancel();
    socket.destroy();
  }
}

class _OutgoingFile {
  const _OutgoingFile(this.source, this.name, this.size);
  final PlatformFile source;
  final String name;
  final int size;
}

class _PendingIncomingTransfer {
  const _PendingIncomingTransfer({
    required this.request,
    required this.decision,
  });
  final IncomingTransferRequest request;
  final Completer<_IncomingDecision> decision;
}

class _IncomingDecision {
  const _IncomingDecision._(this.accepted, this.target);
  const _IncomingDecision.reject() : this._(false, null);
  const _IncomingDecision.accept(ReceiveTarget target) : this._(true, target);

  final bool accepted;
  final ReceiveTarget? target;
}

class _DigestCollector implements Sink<hash.Digest> {
  hash.Digest? _digest;

  String get digestHex {
    final value = _digest;
    if (value == null) throw const StateError('Digest has not completed.');
    return value.toString();
  }

  @override
  void add(hash.Digest data) {
    _digest = data;
  }

  @override
  void close() {}
}

class _IncomingPlaintextStream {
  _IncomingPlaintextStream({
    required this.reader,
    required this.sessionKey,
    required this.fileSize,
    required this.onProgress,
  });

  final SocketByteReader reader;
  final SecretKey sessionKey;
  final int fileSize;
  final void Function(int bytesDone, double bytesPerSecond) onProgress;
  bool verified = false;

  Stream<List<int>> stream() async* {
    final cipher = AesGcm.with256bits();
    final digestSink = _DigestCollector();
    final hashInput = hash.sha256.startChunkedConversion(digestSink);
    var received = 0;
    final watch = Stopwatch()..start();

    while (received < fileSize) {
      final frame = await reader.readFrame();
      if (frame.isEmpty || frame[0] != 1) {
        throw const FormatException('Expected encrypted file data.');
      }
      final box = decodeEncryptedDataFrame(frame);
      final clear = await cipher.decrypt(box, secretKey: sessionKey);
      if (received + clear.length > fileSize) {
        throw const FormatException('Received more file data than advertised.');
      }
      hashInput.add(clear);
      received += clear.length;
      final seconds = watch.elapsedMicroseconds / 1000000.0;
      onProgress(received, seconds <= 0 ? 0 : received / seconds);
      yield clear;
    }

    hashInput.close();
    final completion = await readSecureJsonFrame(reader, sessionKey);
    if (completion['type'] != 'file_complete') {
      throw const FormatException('Missing file completion frame.');
    }
    if (completion['bytes'] != received ||
        completion['sha256'] != digestSink.digestHex) {
      throw const StateError('SHA-256 verification failed.');
    }
    verified = true;
  }
}
