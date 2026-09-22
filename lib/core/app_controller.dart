import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saf/saf.dart';

import 'models.dart';
import 'network/discovery_service.dart';
import 'network/transfer_service.dart';
import 'storage/identity_store.dart';
import 'storage/stats_store.dart';

class AppController extends ChangeNotifier {
  AppController._({
    required AppIdentity identity,
    required IdentityStore identityStore,
    required StatsStore statsStore,
  })  : _identity = identity,
        _identityStore = identityStore,
        _statsStore = statsStore,
        _discovery = DiscoveryService(identity),
        _transfers = TransferService(identity);

  static Future<AppController> create() async {
    final identityStore = IdentityStore();
    final statsStore = StatsStore();
    final identity = await identityStore.load();
    final controller = AppController._(
      identity: identity,
      identityStore: identityStore,
      statsStore: statsStore,
    );
    await controller._initialize();
    return controller;
  }

  AppIdentity _identity;
  final IdentityStore _identityStore;
  final StatsStore _statsStore;
  final DiscoveryService _discovery;
  final TransferService _transfers;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Set<String> _recorded = {};
  List<NearbyDevice> _nearby = const [];
  List<TransferActivity> _activities = const [];
  List<TransferRecord> _records = const [];
  final List<IncomingConnectionRequest> _connections = [];
  final List<IncomingTransferRequest> _incoming = [];

  String? _networkError;
  bool _receiveReady = false;
  bool _transferSendMode = true;
  String? _outgoingPairingPeer;
  String? _outgoingPairingCode;
  String? _lastTransferError;

  AppIdentity get identity => _identity;
  List<NearbyDevice> get nearby => List.unmodifiable(_nearby);
  List<TransferActivity> get activities => List.unmodifiable(_activities);
  List<TransferRecord> get records => List.unmodifiable(_records);
  List<IncomingConnectionRequest> get connections => List.unmodifiable(_connections);
  List<IncomingTransferRequest> get incoming => List.unmodifiable(_incoming);

  IncomingConnectionRequest? get nextConnection =>
      _connections.isEmpty ? null : _connections.first;
  IncomingTransferRequest? get nextIncoming =>
      _incoming.isEmpty ? null : _incoming.first;
  TodayStats get todayStats => _statsStore.todayStats(_records);
  String? get networkError => _networkError;
  bool get receiveReady => _receiveReady;
  bool get transferSendMode => _transferSendMode;
  String? get outgoingPairingPeer => _outgoingPairingPeer;
  String? get outgoingPairingCode => _outgoingPairingCode;
  bool get outgoingBusy => _outgoingPairingPeer != null;
  String? get lastTransferError => _lastTransferError;

  Future<void> _initialize() async {
    _records = await _statsStore.loadRecords();
    _subscriptions.add(_discovery.devices.listen((devices) {
      _nearby = devices;
      notifyListeners();
    }));
    _subscriptions.add(_transfers.incomingConnections.listen((request) {
      if (_receiveReady && !_connections.any((e) => e.id == request.id)) {
        _connections.add(request);
        notifyListeners();
      } else if (!_receiveReady) {
        unawaited(_transfers.rejectConnection(request.id));
      }
    }));
    _subscriptions.add(_transfers.incomingRequests.listen((request) {
      if (_receiveReady && !_incoming.any((e) => e.id == request.id)) {
        _incoming.add(request);
        notifyListeners();
      } else if (!_receiveReady) {
        unawaited(_transfers.rejectIncoming(request.id));
      }
    }));
    _subscriptions.add(_transfers.activityUpdates.listen(_onActivity));

    try {
      await _transfers.start();
      await _discovery.start();
      _activities = _transfers.activities;
    } on Object catch (error) {
      _networkError = error.toString();
    }
    notifyListeners();
  }

  void _onActivity(TransferActivity activity) {
    _activities = _transfers.activities;
    if (activity.status == TransferStatus.completed &&
        _recorded.add(activity.id)) {
      final record = TransferRecord(
        fileName: activity.fileName,
        bytes: activity.fileSize,
        direction: activity.direction,
        completedAt: DateTime.now(),
      );
      _records = [record, ..._records];
      unawaited(_statsStore.addRecord(record));
    }
    notifyListeners();
  }

  Future<void> sendTo(NearbyDevice device) async {
    if (outgoingBusy) return;
    _lastTransferError = null;
    _outgoingPairingPeer = device.name;
    _outgoingPairingCode = null;
    notifyListeners();

    OutgoingTransferSession? session;
    try {
      session = await _transfers.requestConnection(
        device,
        onPairingCode: (code) {
          _outgoingPairingCode = code;
          notifyListeners();
        },
      );
      if (session == null) {
        _lastTransferError =
            'The connection was declined, timed out, or could not be established.';
        return;
      }

      final files = await FilePicker.pickFiles(
        dialogTitle: 'Choose files to send',
        type: FileType.any,
      );
      if (files.isEmpty) {
        await session.close();
        session = null;
        return;
      }

      final ok = await session.sendFiles(files);
      if (!ok) {
        _lastTransferError ??=
            'The transfer was declined or did not complete successfully.';
      }
    } on Object catch (error) {
      _lastTransferError = error.toString();
    } finally {
      if (session != null) {
        await session.close(notifyPeer: false);
      }
      _outgoingPairingPeer = null;
      _outgoingPairingCode = null;
      notifyListeners();
    }
  }

  Future<void> acceptConnection(IncomingConnectionRequest request) async {
    _connections.removeWhere((e) => e.id == request.id);
    notifyListeners();
    await _transfers.acceptConnection(request.id);
  }

  Future<void> rejectConnection(IncomingConnectionRequest request) async {
    _connections.removeWhere((e) => e.id == request.id);
    notifyListeners();
    await _transfers.rejectConnection(request.id);
  }

  Future<void> acceptIncoming(IncomingTransferRequest request) async {
    ReceiveTarget? target;
    if (Platform.isAndroid) {
      final saf = Saf();
      final dir = await saf.pickDirectory(
        writePermission: true,
        persistablePermission: true,
      );
      if (dir != null) {
        target = ReceiveTarget.saf(uri: dir.uri, label: dir.name);
      }
    } else {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: request.files.length == 1
            ? 'Choose where to save ${request.files.first.name}'
            : 'Choose where to save ${request.files.length} files',
      );
      if (path != null) target = ReceiveTarget.path(path);
    }

    if (target == null) {
      notifyListeners();
      return;
    }
    _incoming.removeWhere((e) => e.id == request.id);
    notifyListeners();
    await _transfers.acceptIncoming(request.id, target);
  }

  Future<void> rejectIncoming(IncomingTransferRequest request) async {
    _incoming.removeWhere((e) => e.id == request.id);
    notifyListeners();
    await _transfers.rejectIncoming(request.id);
  }

  void setTransferSendMode(bool sendMode) {
    _transferSendMode = sendMode;
    setReceiveReady(!sendMode);
  }

  void setReceiveReady(bool value) {
    _receiveReady = value;
    if (!value) {
      for (final request in List<IncomingConnectionRequest>.from(_connections)) {
        unawaited(_transfers.rejectConnection(request.id));
      }
      for (final request in List<IncomingTransferRequest>.from(_incoming)) {
        unawaited(_transfers.rejectIncoming(request.id));
      }
      _connections.clear();
      _incoming.clear();
    }
    notifyListeners();
  }

  Future<void> renameDevice(String value) async {
    final updated = await _identityStore.rename(_identity, value);
    if (updated.name == _identity.name) return;
    _identity = updated;
    _discovery.updateIdentity(updated);
    _transfers.updateIdentity(updated);
    notifyListeners();
  }

  Future<void> openPermissions() => openAppSettings();

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(_discovery.dispose());
    unawaited(_transfers.dispose());
    super.dispose();
  }
}
