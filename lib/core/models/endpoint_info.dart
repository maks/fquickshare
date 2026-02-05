import 'device_type.dart';

class EndpointInfo {
  final String fullname;
  final String id;
  final String? name;
  final String? ip;
  final int? port;
  final DeviceType? deviceType;
  final bool present;

  const EndpointInfo({
    required this.fullname,
    required this.id,
    this.name,
    this.ip,
    this.port,
    this.deviceType,
    this.present = true,
  });
}
