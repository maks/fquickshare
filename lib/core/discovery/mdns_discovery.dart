import 'dart:async';
import 'dart:io';

import 'package:mdns_dart/mdns_dart.dart';

import '../models/device_type.dart';
import '../models/endpoint_info.dart';
import '../utils/mdns_utils.dart';

class MdnsDiscovery {
  static const String serviceType = '_FC9F5ED42C8A._tcp';
  static const Duration scanInterval = Duration(seconds: 5);

  final StreamController<EndpointInfo> _endpoints =
      StreamController<EndpointInfo>.broadcast();
  final Map<String, EndpointInfo> _cache = {};
  Timer? _timer;

  Stream<EndpointInfo> get endpoints => _endpoints.stream;

  Future<void> start() async {
    if (_timer != null) {
      return;
    }
    await _scanOnce();
    _timer = Timer.periodic(scanInterval, (_) async {
      await _scanOnce();
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _scanOnce() async {
    List<dynamic> services;
    try {
      services = await MDNSClient.discover(serviceType);
    } catch (_) {
      return;
    }

    final seen = <String>{};
    for (final service in services) {
      final info = await _toEndpointInfo(service);
      if (info == null) {
        continue;
      }
      seen.add(info.fullname);
      if (!_cache.containsKey(info.fullname)) {
        _cache[info.fullname] = info;
        _endpoints.add(info);
      } else {
        _cache[info.fullname] = info;
      }
    }

    final removed = _cache.keys.where((k) => !seen.contains(k)).toList();
    for (final key in removed) {
      final removedInfo = _cache.remove(key);
      if (removedInfo != null) {
        _endpoints.add(
          EndpointInfo(
            fullname: removedInfo.fullname,
            id: removedInfo.id,
            name: removedInfo.name,
            ip: removedInfo.ip,
            port: removedInfo.port,
            deviceType: removedInfo.deviceType,
            present: false,
          ),
        );
      }
    }
  }

  Future<EndpointInfo?> _toEndpointInfo(dynamic service) async {
    try {
      final name = service.name as String?;
      final port = service.port as int?;
      final primary = service.primaryAddress as InternetAddress?;
      if (name == null || port == null || primary == null) {
        return null;
      }

      if (!await _isNotSelfIp(primary)) {
        return null;
      }

      DeviceType? deviceType;
      String? deviceName;
      final txt = service.txt;
      if (txt != null) {
        final parsed = MDNSService.parseTXTRecords(txt);
        final n = parsed['n'];
        if (n != null) {
          final decoded = parseMdnsEndpointInfo(n);
          deviceType = decoded.deviceType;
          deviceName = decoded.name;
        }
      }

      final id = '${primary.address}:$port';
      return EndpointInfo(
        fullname: name,
        id: id,
        name: deviceName,
        ip: primary.address,
        port: port,
        deviceType: deviceType,
        present: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isNotSelfIp(InternetAddress address) async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address == address.address) {
            return false;
          }
        }
      }
    } catch (_) {
      return true;
    }
    return true;
  }
}
