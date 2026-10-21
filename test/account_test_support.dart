import 'package:free_your_launcher/core/accounts.dart';

class MemoryTokenStore implements AccountTokenStore {
  final values = <String, AccountTokens>{};
  @override
  Future<AccountTokens?> read(String id) async => values[id];
  @override
  Future<void> write(String id, AccountTokens tokens) async {
    values[id] = tokens;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}
