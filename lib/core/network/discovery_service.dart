import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'protocol.dart';

class DiscoveryService {
  DiscoveryService(this.identity);

  AppIdentity identity;
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  final Map<String, NearbyDevice> _devices = {};
  final StreamController<List<NearbyDevice>> _controller =
      StreamController<List<NearbyDevice>>.broadcast();

  Stream<List<NearbyDevice>> get devices => _controller.stream;

  void updateIdentity(AppIdentity value) {
    identity = value;
    _announce();
  }

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kDiscoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    socket.listen(
      _onSocketEvent,
      onError: (_) {},
      onDone: () {},
      cancelOnError: false,
    );

    _announce();
    _announceTimer = Timer.periodic(const Duration(seconds: 2), (_) => _announce());
    _cleanupTimer = Timer.periodic(const Duration(seconds: 3), (_) => _removeStale());
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _socket?.receive()) != null) {
      _handleDatagram(datagram!);
    }
  }

  void _handleDatagram(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['magic'] != kDiscoveryMagic) return;
      if (decoded['version'] != kProtocolVersion) return;
      final id = decoded['id'];
      final name = decoded['name'];
      final platform = decoded['platform'];
      final port = decoded['port'];
      if (id is! String ||
          id == identity.id ||
          name is! String ||
          platform is! String ||
          port is! int ||
          port <= 0 ||
          port > 65535) {
        return;
      }

      _devices[id] = NearbyDevice(
        id: id,
        name: name,
        platform: platform,
        address: datagram.address,
        port: port,
        lastSeen: DateTime.now(),
      );
      _emit();
    } on Object {
      // Ignore malformed or unrelated UDP traffic on the discovery port.
    }
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(jsonEncode({
      'magic': kDiscoveryMagic,
      'version': kProtocolVersion,
      'id': identity.id,
      'name': identity.name,
      'platform': identity.platformLabel,
      'port': kTransferPort,
    }));
    try {
      socket.send(payload, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } on Object {
      // The next periodic announcement will retry.
    }
  }

  void _removeStale() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 7));
    final before = _devices.length;
    _devices.removeWhere((_, device) => device.lastSeen.isBefore(cutoff));
    if (_devices.length != before) _emit();
  }

  void _emit() {
    final list = _devices.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(list));
    }
  }

  Future<void> dispose() async {
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
    await _controller.close();
  }
}
