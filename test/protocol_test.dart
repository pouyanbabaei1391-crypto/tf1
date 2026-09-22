import 'package:flutter_test/flutter_test.dart';
import 'package:nexadrop/core/network/protocol.dart';

void main() {
  test('sanitizes unsafe filenames', () {
    expect(sanitizeFileName('../bad:name?.txt'), '.._bad_name_.txt');
    expect(sanitizeFileName('..'), 'received_file');
  });

  test('formats bytes predictably', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1.00 KB');
    expect(formatBytes(1024 * 1024), '1.00 MB');
  });
}
