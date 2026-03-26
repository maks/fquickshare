class UiEvent {
  final String id;
  final String? state;
  final String? transferType;
  final String? sourceName;
  final List<String> files;
  final int totalBytes;
  final int ackBytes;
  final String? pinCode;
  final String? destination;
  final String? url;
  final int timestampMs;

  const UiEvent({
    required this.id,
    this.state,
    this.transferType,
    this.sourceName,
    this.files = const [],
    this.totalBytes = 0,
    this.ackBytes = 0,
    this.pinCode,
    this.destination,
    this.url,
    this.timestampMs = 0,
  });

  factory UiEvent.fromJson(Map<String, dynamic> json) {
    return UiEvent(
      id: json['id'] as String? ?? '',
      state: json['state'] as String?,
      transferType: json['transferType'] as String?,
      sourceName: json['sourceName'] as String?,
      files: (json['files'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      ackBytes: (json['ackBytes'] as num?)?.toInt() ?? 0,
      pinCode: json['pinCode'] as String?,
      destination: json['destination'] as String?,
      url: json['url'] as String?,
      timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isWaitingForConsent => state == 'WaitingForUserConsent';

  UiEvent copyWith({
    String? id,
    String? state,
    String? transferType,
    String? sourceName,
    List<String>? files,
    int? totalBytes,
    int? ackBytes,
    String? pinCode,
    String? destination,
    String? url,
    int? timestampMs,
  }) {
    return UiEvent(
      id: id ?? this.id,
      state: state ?? this.state,
      transferType: transferType ?? this.transferType,
      sourceName: sourceName ?? this.sourceName,
      files: files ?? this.files,
      totalBytes: totalBytes ?? this.totalBytes,
      ackBytes: ackBytes ?? this.ackBytes,
      pinCode: pinCode ?? this.pinCode,
      destination: destination ?? this.destination,
      url: url ?? this.url,
      timestampMs: timestampMs ?? this.timestampMs,
    );
  }
}
