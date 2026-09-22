import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';

class IdentityStore {
  static const _idKey = 'identity.id';
  static const _nameKey = 'identity.name';

  Future<AppIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_idKey);
    if (id == null || id.trim().isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_idKey, id);
    }

    var name = prefs.getString(_nameKey)?.trim();
    if (name == null || name.isEmpty) {
      final platform = AppIdentity.currentPlatformLabel();
      name = '$platform ${id.substring(0, 4).toUpperCase()}';
      await prefs.setString(_nameKey, name);
    }

    return AppIdentity(
      id: id,
      name: name,
      platformLabel: AppIdentity.currentPlatformLabel(),
    );
  }

  Future<AppIdentity> rename(AppIdentity current, String value) async {
    final trimmed = value.trim().replaceAll(RegExp(r'[\r\n\t]+'), ' ');
    if (trimmed.isEmpty) return current;
    final safe = trimmed.length <= 48 ? trimmed : trimmed.substring(0, 48);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, safe);
    return current.copyWith(name: safe);
  }
}
