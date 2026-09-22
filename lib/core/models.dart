import 'dart:io';

class AppIdentity {
  const AppIdentity({
    required this.id,
    required this.name,
    required this.platformLabel,
  });

  final String id;
  final String name;
  final String platformLabel;

  AppIdentity copyWith({String? name}) => AppIdentity(
        id: id,
        name: name ?? this.name,
        platformLabel: platformLabel,
      );

  static String currentPlatformLabel() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isIOS) return 'iOS';
    return Platform.operatingSystem;
  }
}

class NearbyDevice {
  const NearbyDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String platform;
  final InternetAddress address;
  final int port;
  final DateTime lastSeen;
}

enum TransferDirection { sent, received }

enum TransferStatus {
  waiting,
  connecting,
  transferring,
  completed,
  failed,
  rejected,
}

class TransferActivity {
  const TransferActivity({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.status,
    required this.peerName,
    required this.startedAt,
    this.bytesDone = 0,
    this.bytesPerSecond = 0,
    this.pairingCode,
    this.error,
  });

  final String id;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final TransferStatus status;
  final String peerName;
  final DateTime startedAt;
  final int bytesDone;
  final double bytesPerSecond;
  final String? pairingCode;
  final String? error;

  double get progress {
    if (fileSize <= 0) return status == TransferStatus.completed ? 1 : 0;
    return (bytesDone / fileSize).clamp(0.0, 1.0).toDouble();
  }

  TransferActivity copyWith({
    TransferStatus? status,
    int? bytesDone,
    double? bytesPerSecond,
    String? pairingCode,
    String? error,
  }) {
    return TransferActivity(
      id: id,
      fileName: fileName,
      fileSize: fileSize,
      direction: direction,
      status: status ?? this.status,
      peerName: peerName,
      startedAt: startedAt,
      bytesDone: bytesDone ?? this.bytesDone,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      pairingCode: pairingCode ?? this.pairingCode,
      error: error ?? this.error,
    );
  }
}

class TransferRecord {
  const TransferRecord({
    required this.fileName,
    required this.bytes,
    required this.direction,
    required this.completedAt,
  });

  final String fileName;
  final int bytes;
  final TransferDirection direction;
  final DateTime completedAt;

  Map<String, Object> toJson() => {
        'fileName': fileName,
        'bytes': bytes,
        'direction': direction.name,
        'completedAt': completedAt.toIso8601String(),
      };

  static TransferRecord? fromJson(Map<String, dynamic> json) {
    try {
      final directionName = json['direction'] as String;
      return TransferRecord(
        fileName: json['fileName'] as String,
        bytes: json['bytes'] as int,
        direction: TransferDirection.values.byName(directionName),
        completedAt: DateTime.parse(json['completedAt'] as String),
      );
    } on Object {
      return null;
    }
  }
}

class TodayStats {
  const TodayStats({
    required this.sentBytes,
    required this.receivedBytes,
    required this.fileCount,
  });

  final int sentBytes;
  final int receivedBytes;
  final int fileCount;
  int get totalBytes => sentBytes + receivedBytes;
}

class IncomingConnectionRequest {
  const IncomingConnectionRequest({
    required this.id,
    required this.senderName,
    required this.senderPlatform,
    required this.pairingCode,
  });

  final String id;
  final String senderName;
  final String senderPlatform;
  final String pairingCode;
}

class IncomingFileInfo {
  const IncomingFileInfo({required this.name, required this.size});
  final String name;
  final int size;
}

class IncomingTransferRequest {
  const IncomingTransferRequest({
    required this.id,
    required this.files,
    required this.senderName,
    required this.senderPlatform,
    required this.pairingCode,
  });

  final String id;
  final List<IncomingFileInfo> files;
  final String senderName;
  final String senderPlatform;
  final String pairingCode;

  String get fileName {
    if (files.isEmpty) return 'No file';
    if (files.length == 1) return files.first.name;
    return '${files.first.name} + ${files.length - 1} more';
  }

  int get fileSize => files.fold<int>(0, (sum, file) => sum + file.size);
}

enum ReceiveTargetType { localPath, androidSaf }

class ReceiveTarget {
  const ReceiveTarget._({
    required this.type,
    required this.value,
    required this.label,
  });

  factory ReceiveTarget.path(String path) => ReceiveTarget._(
        type: ReceiveTargetType.localPath,
        value: path,
        label: path,
      );

  factory ReceiveTarget.saf({required String uri, required String label}) =>
      ReceiveTarget._(
        type: ReceiveTargetType.androidSaf,
        value: uri,
        label: label,
      );

  final ReceiveTargetType type;
  final String value;
  final String label;
}
