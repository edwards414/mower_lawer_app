import 'dart:convert';
import 'dart:typed_data';

/// `mrelay1` framing between the app and the fleet backend relay
/// (mower_path_planning docs/BACKEND_ARCHITECTURE.md §5.1).
///
/// One relay WebSocket message is capped at 1 MiB, rosbridge messages are
/// not, so every rosbridge message is cut into chunks here and glued back
/// together on the other side. Each WebSocket message is binary:
///
///   byte 0  0x01 text (last chunk)   0x11 text (more follows)
///           0x02 binary (last chunk) 0x12 binary (more follows)
///   byte 1… chunk payload
class RelayFraming {
  const RelayFraming._();

  static const subprotocol = 'mrelay1';
  static const textFinal = 0x01;
  static const textMore = 0x11;
  static const binaryFinal = 0x02;
  static const binaryMore = 0x12;
  static const moreBit = 0x10;
  static const chunkSize = 512 * 1024;
  static const maxMessage = 64 * 1024 * 1024;

  static bool isFrameType(int t) =>
      t == textFinal || t == textMore || t == binaryFinal || t == binaryMore;

  /// Frames for one rosbridge text message.
  static List<Uint8List> encodeText(String text, {int chunkSize = chunkSize}) {
    return _encode(utf8.encode(text), textFinal, textMore, chunkSize);
  }

  static List<Uint8List> encodeBinary(List<int> bytes, {int chunkSize = chunkSize}) {
    return _encode(bytes, binaryFinal, binaryMore, chunkSize);
  }

  static List<Uint8List> _encode(List<int> payload, int finalType, int moreType, int chunkSize) {
    if (payload.isEmpty) {
      return [Uint8List.fromList([finalType])];
    }
    final frames = <Uint8List>[];
    for (var start = 0; start < payload.length; start += chunkSize) {
      final end = start + chunkSize >= payload.length ? payload.length : start + chunkSize;
      final frame = Uint8List(1 + end - start);
      frame[0] = end == payload.length ? finalType : moreType;
      frame.setRange(1, frame.length, payload, start);
      frames.add(frame);
    }
    return frames;
  }
}

/// Glues incoming chunk frames back into rosbridge messages.
class RelayReassembler {
  RelayReassembler({this.maxMessage = RelayFraming.maxMessage});

  final int maxMessage;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Feed one WebSocket message. Returns the complete message when this
  /// frame finishes one: a [String] for text, a [Uint8List] for binary;
  /// `null` while more chunks are expected. Throws [FormatException] on a
  /// malformed frame or when a message grows past [maxMessage].
  Object? feed(List<int> frame) {
    if (frame.isEmpty || !RelayFraming.isFrameType(frame[0])) {
      throw const FormatException('bad mrelay1 frame');
    }
    final type = frame[0];
    if (_buffer.length + frame.length - 1 > maxMessage) {
      _buffer.clear();
      throw const FormatException('relayed message too large');
    }
    _buffer.add(frame is Uint8List ? Uint8List.sublistView(frame, 1) : frame.sublist(1));
    if (type & RelayFraming.moreBit != 0) {
      return null;
    }
    final data = _buffer.takeBytes();
    if (type == RelayFraming.textFinal) {
      return utf8.decode(data, allowMalformed: true);
    }
    return data;
  }

  void reset() => _buffer.clear();
}
