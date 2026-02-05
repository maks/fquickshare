import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mdns_dart/mdns_dart.dart';

import '../models/device_type.dart';
import '../utils/mdns_utils.dart';

class MdnsAdvertiser {
  static const String serviceType = '_FC9F5ED42C8A._tcp.';

  MDNSServer? _server;
  MDNSService? _service;

  Future<void> start({
    required int port,
    required Uint8List endpointId,
    DeviceType deviceType = DeviceType.laptop,
  }) async {
    if (_server != null) {
      return;
    }

    final hostname = Platform.localHostname;
    final instanceName = genMdnsName(endpointId);
    final endpointInfo = genMdnsEndpointInfo(deviceType, hostname);
    final txt = MDNSService.createTXTRecords({'n': endpointInfo});

    final ipv4 = await _collectIPv4Addresses();
    _service = await MDNSService.create(
      instance: instanceName,
      service: serviceType,
      hostName: hostname,
      port: port,
      ips: ipv4.isEmpty ? [InternetAddress.anyIPv4] : ipv4,
      txt: txt,
    );

    final zone = MultiServiceZone()..addService(_service!);
    final serverConfig = MDNSServerConfig(zone: zone);

    _server = MDNSServer(serverConfig);
    await _server!.start();
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
    _service = null;
  }

  Future<List<InternetAddress>> _collectIPv4Addresses() async {
    final result = <InternetAddress>[];
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) {
            continue;
          }
          if (addr.isLoopback) {
            continue;
          }
          if (addr.address.startsWith('169.254.')) {
            continue;
          }
          result.add(addr);
        }
      }
    } catch (_) {
      return result;
    }
    return result;
  }
}
