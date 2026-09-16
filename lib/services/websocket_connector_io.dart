import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectWebSocket(
  Uri uri, {
  Map<String, dynamic> headers = const {},
}) {
  return IOWebSocketChannel.connect(
    uri,
    headers: headers.isEmpty ? null : headers,
    pingInterval: const Duration(seconds: 20),
  );
}
