import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_connector_stub.dart'
    if (dart.library.io) 'websocket_connector_io.dart'
    as platform;

WebSocketChannel connectWebSocket(
  Uri uri, {
  Map<String, dynamic> headers = const {},
  List<String> protocols = const [],
}) {
  return platform.connectWebSocket(uri, headers: headers, protocols: protocols);
}
