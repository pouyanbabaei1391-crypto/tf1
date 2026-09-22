import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

class StatsStore {
  static const _recordsKey = 'transfer.records.v1';
  static const _retention = Duration(days: 90);

  Future<List<TransferRecord>> loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recordsKey);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final cutoff = DateTime.now().subtract(_retention);
      final records = <TransferRecord>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final record = TransferRecord.fromJson(Map<String, dynamic>.from(item));
        if (record != null && record.completedAt.isAfter(cutoff)) {
          records.add(record);
        }
      }
      records.sort((a, b) => b.completedAt.compareTo(a.completedAt));
      return records;
    } on Object {
      return const [];
    }
  }

  Future<void> addRecord(TransferRecord record) async {
    final records = await loadRecords();
    final updated = [record, ...records].take(1000).toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recordsKey,
      jsonEncode(updated.map((e) => e.toJson()).toList(growable: false)),
    );
  }

  TodayStats todayStats(List<TransferRecord> records) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    var sent = 0;
    var received = 0;
    var count = 0;
    for (final record in records) {
      if (record.completedAt.isBefore(start)) continue;
      count++;
      if (record.direction == TransferDirection.sent) {
        sent += record.bytes;
      } else {
        received += record.bytes;
      }
    }
    return TodayStats(sentBytes: sent, receivedBytes: received, fileCount: count);
  }
}
