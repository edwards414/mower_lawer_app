import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mower_stdio/services/relay_framing.dart';

void main() {
  test('short text is one final frame', () {
    final frames = RelayFraming.encodeText('{"op":"subscribe"}');
    expect(frames, hasLength(1));
    expect(frames.single[0], RelayFraming.textFinal);
    expect(utf8.decode(frames.single.sublist(1)), '{"op":"subscribe"}');
    expect(RelayReassembler().feed(frames.single), '{"op":"subscribe"}');
  });

  test('large text is chunked and reassembled', () {
    final big = 'x' * (RelayFraming.chunkSize * 2 + 5);
    final frames = RelayFraming.encodeText(big);
    expect(frames.map((f) => f[0]).toList(), [
      RelayFraming.textMore,
      RelayFraming.textMore,
      RelayFraming.textFinal,
    ]);
    final r = RelayReassembler();
    expect(r.feed(frames[0]), isNull);
    expect(r.feed(frames[1]), isNull);
    expect(r.feed(frames[2]), big);
  });

  test('binary, empty and malformed frames', () {
    final frames = RelayFraming.encodeBinary([0, 1, 2], chunkSize: 2);
    expect(frames.map((f) => f[0]).toList(), [RelayFraming.binaryMore, RelayFraming.binaryFinal]);
    final r = RelayReassembler();
    expect(r.feed(frames[0]), isNull);
    expect(r.feed(frames[1]), Uint8List.fromList([0, 1, 2]));
    expect(RelayFraming.encodeText(''), [Uint8List.fromList([RelayFraming.textFinal])]);
    expect(RelayReassembler().feed([RelayFraming.textFinal]), '');
    expect(() => RelayReassembler().feed(const []), throwsFormatException);
    expect(() => RelayReassembler().feed([0x09, 1]), throwsFormatException);
    final small = RelayReassembler(maxMessage: 4);
    expect(() => small.feed([RelayFraming.textMore, 1, 2, 3, 4, 5]), throwsFormatException);
    expect(small.feed([RelayFraming.textFinal, 0x6f, 0x6b]), 'ok');
  });
}
