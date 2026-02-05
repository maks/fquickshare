enum DeviceType {
  unknown,
  phone,
  tablet,
  laptop,
}

DeviceType deviceTypeFromRaw(int raw) {
  switch (raw) {
    case 1:
      return DeviceType.phone;
    case 2:
      return DeviceType.tablet;
    case 3:
      return DeviceType.laptop;
    default:
      return DeviceType.unknown;
  }
}
