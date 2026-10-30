import 'package:flutter/foundation.dart';

import 'storage/json_store.dart';

/// The privacy ledger: an append-only record of everything the app did,
/// including the only network traffic it ever makes (model downloads).
class LedgerEntry {
  LedgerEntry({required this.time, required this.kind, required this.detail, this.network = false});

  final DateTime time;
  final String kind;
  final String detail;
  final bool network;

  Map<String, dynamic> toJson() => {'t': time.toIso8601String(), 'k': kind, 'd': detail, 'n': network};

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
    time: DateTime.parse(j['t'] as String),
    kind: j['k'] as String,
    detail: j['d'] as String,
    network: j['n'] as bool? ?? false,
  );
}

class Ledger extends ChangeNotifier {
  Ledger(this._store);

  final JsonStore _store;
  static const _key = 'ledger';
  static const _max = 500;
  final List<LedgerEntry> entries = [];

  Future<void> load() async {
    final raw = await _store.read(_key) as List?;
    if (raw != null) {
      entries
        ..clear()
        ..addAll(raw.map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e as Map))));
    }
  }

  int get networkEvents => entries.where((e) => e.network).length;

  Future<void> record(String kind, String detail, {bool network = false}) async {
    entries.insert(0, LedgerEntry(time: DateTime.now(), kind: kind, detail: detail, network: network));
    if (entries.length > _max) entries.removeRange(_max, entries.length);
    notifyListeners();
    await _store.write(_key, entries.map((e) => e.toJson()).toList());
  }

  Future<void> clear() async {
    entries.clear();
    notifyListeners();
    await _store.delete(_key);
  }
}
