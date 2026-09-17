import 'package:uuid/uuid.dart';

/// Every synchronisable row gets a client-generated id. Never autoincrement.
abstract interface class IdGenerator {
  String generate();
}

/// UUIDv7: time-ordered, so ids sort chronologically and index well.
final class UuidV7Generator implements IdGenerator {
  const UuidV7Generator();

  static const _uuid = Uuid();

  @override
  String generate() => _uuid.v7();
}
