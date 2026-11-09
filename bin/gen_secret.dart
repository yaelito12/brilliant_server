import 'dart:convert';
import 'dart:math';

/// Imprime un secreto aleatorio para JWT_SECRET (48 bytes en base64url).
void main() {
  final r = Random.secure();
  print(base64Url.encode(List<int>.generate(48, (_) => r.nextInt(256))).replaceAll('=', ''));
}
