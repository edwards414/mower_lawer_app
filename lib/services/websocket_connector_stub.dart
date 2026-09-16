import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectWebSocket(
  Uri uri, {
  Map<String, dynamic> headers = const {},
}) {
  // Browser WebSocket APIs do not allow arbitrary request headers. Web builds
  // must authenticate to Cloudflare Access with its browser session cookie.
  return WebSocketChannel.connect(uri);
}
