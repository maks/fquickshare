import 'dart:async';
import 'dart:io';

class TcpTransport {
  ServerSocket? _server;

  Future<int> startServer({InternetAddress? address, int port = 0}) async {
    _server = await ServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      port,
    );
    return _server!.port;
  }

  Future<void> stopServer() async {
    await _server?.close();
    _server = null;
  }

  Stream<Socket> get connections {
    final server = _server;
    if (server == null) {
      return const Stream.empty();
    }
    return server;
  }
}
