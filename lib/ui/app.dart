import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/network/protocol.dart';

class NexaDropApp extends StatelessWidget {
  const NexaDropApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF7C6DFF);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: const Color(0xFF12131A),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexaDrop',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0D0E13),
        cardTheme: const CardThemeData(
          color: Color(0xFF151720),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
            side: BorderSide(color: Color(0xFF262936)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF171923),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF2C3040)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF2C3040)),
          ),
        ),
      ),
      home: _Shell(controller: controller),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell({required this.controller});
  final AppController controller;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;
  String? _shownConnection;
  String? _shownIncoming;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onControllerChanged());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted || _dialogOpen) return;

    final connection = widget.controller.nextConnection;
    if (connection != null && connection.id != _shownConnection) {
      _shownConnection = connection.id;
      _dialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _ConnectionDialog(
            request: connection,
            onReject: () async {
              Navigator.of(context).pop();
              await widget.controller.rejectConnection(connection);
            },
            onAccept: () async {
              Navigator.of(context).pop();
              await widget.controller.acceptConnection(connection);
            },
          ),
        );
        if (!mounted) return;
        _dialogOpen = false;
        _shownConnection = null;
        _onControllerChanged();
      });
      return;
    }

    final request = widget.controller.nextIncoming;
    if (request == null || request.id == _shownIncoming) return;
    _shownIncoming = request.id;
    _dialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _IncomingDialog(
          request: request,
          onReject: () async {
            Navigator.of(context).pop();
            await widget.controller.rejectIncoming(request);
          },
          onAccept: () async {
            Navigator.of(context).pop();
            await widget.controller.acceptIncoming(request);
          },
        ),
      );
      if (!mounted) return;
      _dialogOpen = false;
      _shownIncoming = null;
      _onControllerChanged();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final pages = <Widget>[
          _HomePage(controller: widget.controller, onOpenTransfer: () => setState(() => _index = 1)),
          _TransferPage(controller: widget.controller),
          _HistoryPage(controller: widget.controller),
          _SettingsPage(controller: widget.controller),
        ];
        final wide = MediaQuery.sizeOf(context).width >= 920;
        if (wide) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (value) => setState(() => _index = value),
                      extended: MediaQuery.sizeOf(context).width >= 1180,
                      leading: const Padding(
                        padding: EdgeInsets.only(bottom: 24),
                        child: _BrandMark(),
                      ),
                      destinations: const [
                        NavigationRailDestination(icon: Icon(Icons.dashboard_rounded), label: Text('Dashboard')),
                        NavigationRailDestination(icon: Icon(Icons.swap_horiz_rounded), label: Text('Transfer')),
                        NavigationRailDestination(icon: Icon(Icons.history_rounded), label: Text('History')),
                        NavigationRailDestination(icon: Icon(Icons.settings_rounded), label: Text('Settings')),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: pages[_index]),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(child: pages[_index]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_rounded), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.swap_horiz_rounded), label: 'Transfer'),
              NavigationDestination(icon: Icon(Icons.history_rounded), label: 'History'),
              NavigationDestination(icon: Icon(Icons.settings_rounded), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({required this.controller, required this.onOpenTransfer});
  final AppController controller;
  final VoidCallback onOpenTransfer;

  @override
  Widget build(BuildContext context) {
    final stats = controller.todayStats;
    return _PageFrame(
      title: 'Good to see you',
      subtitle: '${controller.identity.name} • ${controller.identity.platformLabel}',
      trailing: _StatusPill(
        label: controller.networkError == null ? '${controller.nearby.length} nearby' : 'Network issue',
        ok: controller.networkError == null,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final statsCard = _StatsCard(stats: stats);
          final actionCard = _QuickActions(controller: controller, onOpenTransfer: onOpenTransfer);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (controller.networkError != null) ...[
                _ErrorBanner(message: controller.networkError!, onSettings: controller.openPermissions),
                const SizedBox(height: 16),
              ],
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: statsCard),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: actionCard),
                  ],
                )
              else ...[
                statsCard,
                const SizedBox(height: 16),
                actionCard,
              ],
              const SizedBox(height: 24),
              _SectionHeader(title: 'Nearby devices', action: TextButton(onPressed: onOpenTransfer, child: const Text('View all'))),
              const SizedBox(height: 10),
              _NearbyPreview(controller: controller, onOpenTransfer: onOpenTransfer),
              const SizedBox(height: 24),
              const _SectionHeader(title: 'Recent activity'),
              const SizedBox(height: 10),
              _ActivityList(activities: controller.activities.take(4).toList()),
            ],
          );
        },
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});
  final TodayStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: CustomPaint(
                painter: _TransferDonutPainter(sent: stats.sentBytes, received: stats.receivedBytes),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(formatBytes(stats.totalBytes), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text('today', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Today’s transfer', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 18),
                  _MetricRow(icon: Icons.arrow_upward_rounded, label: 'Sent', value: formatBytes(stats.sentBytes)),
                  const SizedBox(height: 10),
                  _MetricRow(icon: Icons.arrow_downward_rounded, label: 'Received', value: formatBytes(stats.receivedBytes)),
                  const SizedBox(height: 10),
                  _MetricRow(icon: Icons.description_outlined, label: 'Files', value: '${stats.fileCount}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.controller, required this.onOpenTransfer});
  final AppController controller;
  final VoidCallback onOpenTransfer;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Transfer', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Encrypted peer-to-peer transfer on your local network.', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: () {
                controller.setTransferSendMode(true);
                onOpenTransfer();
              },
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send files'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                controller.setTransferSendMode(false);
                onOpenTransfer();
              },
              icon: const Icon(Icons.download_rounded),
              label: const Text('Receive'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferPage extends StatefulWidget {
  const _TransferPage({required this.controller});
  final AppController controller;

  @override
  State<_TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<_TransferPage> {
  late bool _sendMode;

  @override
  void initState() {
    super.initState();
    _sendMode = widget.controller.transferSendMode;
  }

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: 'Transfer',
      subtitle: 'Choose a nearby device and move files securely.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.send_rounded), label: Text('Send')),
              ButtonSegment(value: false, icon: Icon(Icons.download_rounded), label: Text('Receive')),
            ],
            selected: {_sendMode},
            onSelectionChanged: (value) {
              setState(() => _sendMode = value.first);
              widget.controller.setTransferSendMode(value.first);
            },
          ),
          const SizedBox(height: 20),
          if (_sendMode && widget.controller.outgoingBusy) ...[
            _OutgoingPairingCard(controller: widget.controller),
            const SizedBox(height: 20),
          ],
          if (_sendMode && widget.controller.lastTransferError != null) ...[
            _TransferErrorCard(message: widget.controller.lastTransferError!),
            const SizedBox(height: 20),
          ],
          if (!_sendMode)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Row(
                  children: [
                    const _PulseDot(),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Ready to receive', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text('A permission request will appear before any file is accepted.', style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    Switch(value: widget.controller.receiveReady, onChanged: widget.controller.setReceiveReady),
                  ],
                ),
              ),
            ),
          if (!_sendMode) const SizedBox(height: 20),
          _SectionHeader(title: _sendMode ? 'Select a device' : 'Devices on this network'),
          const SizedBox(height: 10),
          if (widget.controller.nearby.isEmpty)
            const _EmptyState(
              icon: Icons.radar_rounded,
              title: 'Scanning for nearby devices',
              body: 'Open NexaDrop on the other phone or PC and connect both devices to the same Wi‑Fi/network.',
            )
          else
            ...widget.controller.nearby.map(
              (device) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _DeviceTile(
                  device: device,
                  actionLabel: _sendMode ? 'Send' : 'Online',
                  onTap: _sendMode ? () => widget.controller.sendTo(device) : null,
                ),
              ),
            ),
          const SizedBox(height: 24),
          const _SectionHeader(title: 'Transfers'),
          const SizedBox(height: 10),
          _ActivityList(activities: widget.controller.activities),
        ],
      ),
    );
  }
}

class _HistoryPage extends StatelessWidget {
  const _HistoryPage({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: 'History',
      subtitle: 'Completed transfers from the last 90 days.',
      child: controller.records.isEmpty
          ? const _EmptyState(icon: Icons.history_toggle_off_rounded, title: 'No transfers yet', body: 'Completed transfers will appear here.')
          : Column(
              children: controller.records.take(100).map((record) {
                final sent = record.direction == TransferDirection.sent;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Icon(sent ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)),
                      title: Text(record.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_dateTimeLabel(record.completedAt)),
                      trailing: Text(formatBytes(record.bytes), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.controller});
  final AppController controller;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final TextEditingController _name = TextEditingController(text: widget.controller.identity.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: 'Settings',
      subtitle: 'Device identity and local-network access.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device name', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(controller: _name, decoration: const InputDecoration(hintText: 'My laptop')),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(onPressed: () => widget.controller.renameDevice(_name.text), child: const Text('Save name')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lan_rounded),
              title: const Text('Local network permission'),
              subtitle: const Text('Required for discovering and connecting to nearby devices.'),
              trailing: TextButton(onPressed: widget.controller.openPermissions, child: const Text('Open settings')),
            ),
          ),
          const SizedBox(height: 16),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Security', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  SizedBox(height: 8),
                  Text('Transfers use ephemeral X25519 key exchange, HKDF-SHA256 key derivation, AES-256-GCM encrypted chunks, and final SHA-256 verification.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionDialog extends StatelessWidget {
  const _ConnectionDialog({
    required this.request,
    required this.onReject,
    required this.onAccept,
  });

  final IncomingConnectionRequest request;
  final Future<void> Function() onReject;
  final Future<void> Function() onAccept;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.devices_other_rounded, size: 34),
      title: const Text('Connection request'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${request.senderName} (${request.senderPlatform}) wants permission to connect.',
            ),
            const SizedBox(height: 16),
            Text('Secure code', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SelectableText(
              '${request.pairingCode.substring(0, 3)} ${request.pairingCode.substring(3)}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Compare this code with the sender before allowing a sensitive transfer.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: onReject, child: const Text('Reject')),
        FilledButton.icon(
          onPressed: onAccept,
          icon: const Icon(Icons.check_rounded),
          label: const Text('Allow device'),
        ),
      ],
    );
  }
}

class _TransferErrorCard extends StatelessWidget {
  const _TransferErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _OutgoingPairingCard extends StatelessWidget {
  const _OutgoingPairingCard({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final code = controller.outgoingPairingCode;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Waiting for ${controller.outgoingPairingPeer ?? 'device'}',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    code == null
                        ? 'Establishing a secure connection…'
                        : 'Secure code: ${code.substring(0, 3)} ${code.substring(3)}',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingDialog extends StatelessWidget {
  const _IncomingDialog({required this.request, required this.onReject, required this.onAccept});
  final IncomingTransferRequest request;
  final Future<void> Function() onReject;
  final Future<void> Function() onAccept;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.shield_rounded, size: 34),
      title: const Text('Incoming transfer'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${request.senderName} (${request.senderPlatform}) wants to send ${request.files.length == 1 ? 'a file' : '${request.files.length} files'}:'),
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: const Icon(Icons.insert_drive_file_rounded),
                title: Text(request.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(formatBytes(request.fileSize)),
              ),
            ),
            const SizedBox(height: 14),
            Text('Secure code', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SelectableText(
              '${request.pairingCode.substring(0, 3)} ${request.pairingCode.substring(3)}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 3),
            ),
            const SizedBox(height: 6),
            Text('For sensitive transfers, compare this code with the sender before accepting.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: onReject, child: const Text('Reject')),
        FilledButton.icon(onPressed: onAccept, icon: const Icon(Icons.folder_open_rounded), label: const Text('Choose location & accept')),
      ],
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.subtitle, required this.child, this.trailing});
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 5),
                        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 12), trailing!],
                ],
              ),
              const SizedBox(height: 28),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _NearbyPreview extends StatelessWidget {
  const _NearbyPreview({required this.controller, required this.onOpenTransfer});
  final AppController controller;
  final VoidCallback onOpenTransfer;

  @override
  Widget build(BuildContext context) {
    if (controller.nearby.isEmpty) {
      return const _EmptyState(icon: Icons.radar_rounded, title: 'No nearby devices yet', body: 'NexaDrop automatically scans the local network.');
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: controller.nearby.take(4).map((device) => SizedBox(
        width: 280,
        child: _DeviceTile(
          device: device,
          actionLabel: 'Open',
          onTap: () {
            controller.setTransferSendMode(true);
            onOpenTransfer();
          },
        ),
      )).toList(),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.actionLabel, this.onTap});
  final NearbyDevice device;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isPhone = device.platform.toLowerCase().contains('android');
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(child: Icon(isPhone ? Icons.smartphone_rounded : Icons.laptop_windows_rounded)),
        title: Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${device.platform} • ${device.address.address}'),
        trailing: onTap == null ? Text(actionLabel) : FilledButton.tonal(onPressed: onTap, child: Text(actionLabel)),
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.activities});
  final List<TransferActivity> activities;

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) {
      return const _EmptyState(icon: Icons.swap_vert_circle_outlined, title: 'Nothing moving right now', body: 'Active and recently completed transfers appear here.');
    }
    return Column(
      children: activities.map((activity) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(child: Icon(activity.direction == TransferDirection.sent ? Icons.north_east_rounded : Icons.south_west_rounded)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(activity.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                          const SizedBox(width: 10),
                          Text(_statusLabel(activity.status), style: Theme.of(context).textTheme.labelMedium),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('${activity.peerName} • ${formatBytes(activity.bytesDone)} / ${formatBytes(activity.fileSize)}${activity.bytesPerSecond > 0 ? ' • ${formatSpeed(activity.bytesPerSecond)}' : ''}'),
                      if (activity.pairingCode != null &&
                          (activity.status == TransferStatus.waiting || activity.status == TransferStatus.transferring)) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Secure code: ${activity.pairingCode!.substring(0, 3)} ${activity.pairingCode!.substring(3)}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                      if (activity.status == TransferStatus.transferring) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: activity.progress),
                      ],
                      if (activity.error != null) ...[
                        const SizedBox(height: 5),
                        Text(activity.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      )).toList(),
    );
  }
}

class _TransferDonutPainter extends CustomPainter {
  _TransferDonutPainter({required this.sent, required this.received});
  final int sent;
  final int received;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 10;
    final stroke = 13.0;
    final background = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF272A36);
    canvas.drawCircle(center, radius, background);
    final total = sent + received;
    if (total <= 0) return;
    final sentSweep = math.pi * 2 * sent / total;
    final sentPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF8B7CFF);
    final receivedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF49D8B1);
    const start = -math.pi / 2;
    if (sent > 0) canvas.drawArc(rect.deflate(10), start, sentSweep, false, sentPaint);
    if (received > 0) canvas.drawArc(rect.deflate(10), start + sentSweep, math.pi * 2 - sentSweep, false, receivedPaint);
  }

  @override
  bool shouldRepaint(covariant _TransferDonutPainter oldDelegate) => sent != oldDelegate.sent || received != oldDelegate.received;
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
      if (action != null) action!,
    ],
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: ok ? const Color(0xFF183029) : Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(ok ? Icons.wifi_rounded : Icons.warning_amber_rounded, size: 16),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ]),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onSettings});
  final String message;
  final Future<void> Function() onSettings;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error),
        const SizedBox(width: 12),
        Expanded(child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis)),
        TextButton(onPressed: onSettings, child: const Text('Settings')),
      ]),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
        ]),
      ),
    ),
  );
}

class _PulseDot extends StatelessWidget {
  const _PulseDot();
  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: const BoxDecoration(color: Color(0xFF49D8B1), shape: BoxShape.circle),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF8B7CFF), Color(0xFF49D8B1)]),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.bolt_rounded, color: Colors.white),
      ),
      const SizedBox(width: 10),
      const Text('NexaDrop', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    ],
  );
}

String _statusLabel(TransferStatus status) => switch (status) {
  TransferStatus.waiting => 'Waiting',
  TransferStatus.connecting => 'Connecting',
  TransferStatus.transferring => 'Transferring',
  TransferStatus.completed => 'Completed',
  TransferStatus.failed => 'Failed',
  TransferStatus.rejected => 'Rejected',
};

String _dateTimeLabel(DateTime value) {
  final now = DateTime.now();
  final sameDay = value.year == now.year && value.month == now.month && value.day == now.day;
  final hh = value.hour.toString().padLeft(2, '0');
  final mm = value.minute.toString().padLeft(2, '0');
  if (sameDay) return 'Today • $hh:$mm';
  return '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')} • $hh:$mm';
}
