import 'dart:typed_data';

/// An immutable 256-bit PDQ hash.
///
/// Bytes are in canonical hexadecimal order (most significant byte first),
/// matching Meta's Hash256.format(), not native-memory word order.
final class PdqHash {
  PdqHash._(this._bytes);

  /// Copies exactly 32 bytes in canonical, big-endian order.
  factory PdqHash.fromBytes(List<int> bytes) {
    if (bytes.length != 32 || bytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError.value(bytes, 'bytes', 'Expected exactly 32 bytes');
    }
    return PdqHash._(List<int>.unmodifiable(bytes));
  }

  /// Parses exactly 64 hexadecimal digits, without whitespace or a prefix.
  factory PdqHash.fromHex(String hex) {
    if (hex.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
      throw FormatException('Expected exactly 64 hexadecimal digits', hex);
    }
    return PdqHash.fromBytes([
      for (var i = 0; i < 64; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  final List<int> _bytes;

  /// Returns a copy; modifying it does not modify this hash.
  Uint8List toBytes() => Uint8List.fromList(_bytes);

  String toHex() =>
      _bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Number of differing bits, from 0 (identical) to 256.
  int hammingDistance(PdqHash other) {
    var distance = 0;
    for (var i = 0; i < 32; i++) {
      var bits = _bytes[i] ^ other._bytes[i];
      while (bits != 0) {
        bits &= bits - 1;
        distance++;
      }
    }
    return distance;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PdqHash && hammingDistance(other) == 0;

  @override
  int get hashCode => Object.hashAll(_bytes);

  @override
  String toString() => toHex();
}

/// A PDQ hash and Meta's image-domain quality score.
final class PdqResult {
  const PdqResult(this.hash, this.quality);

  final PdqHash hash;

  /// 0 to 100. Low-quality images are poor candidates for matching.
  final int quality;
}
