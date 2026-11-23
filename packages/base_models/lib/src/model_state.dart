enum ModelStatus { absent, downloading, ready, failed }

/// What this device knows about one model.
class ModelState {
  const ModelState(
    this.status, {
    this.progress = 0,
    this.error,
    this.users = const {},
    this.busyElsewhere = false,
    this.inSibling = false,
  });

  static const absent = ModelState(ModelStatus.absent);

  final ModelStatus status;

  /// 0..1 while downloading.
  final double progress;
  final String? error;

  /// App ids that use this model on this device (from the shared registry).
  final Set<String> users;

  /// Another app on this device is downloading it right now.
  final bool busyElsewhere;

  /// Not in this app's store yet, but another app on this device has every
  /// file (Android): using it copies them, with no download.
  final bool inSibling;

  bool get isReady => status == ModelStatus.ready;

  ModelState copyWith({ModelStatus? status, double? progress, String? error, Set<String>? users, bool? busyElsewhere, bool? inSibling}) =>
      ModelState(
        status ?? this.status,
        progress: progress ?? this.progress,
        error: error,
        users: users ?? this.users,
        busyElsewhere: busyElsewhere ?? this.busyElsewhere,
        inSibling: inSibling ?? this.inSibling,
      );
}

/// Thrown when a model is needed but the user has turned on "never go online".
class OfflineException implements Exception {
  OfflineException(this.modelName);
  final String modelName;
  @override
  String toString() =>
      '$modelName isn\'t on this device yet, and "never go online" is on. Turn it off on the privacy page to download it once.';
}

class ChecksumMismatch implements Exception {
  ChecksumMismatch(this.file, this.expected, this.actual);
  final String file;
  final String expected;
  final String actual;
  @override
  String toString() => 'The download of $file was damaged (checksum mismatch), so it was thrown away. Try again.';
}

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download cancelled';
}

/// Installs an SDK-managed model into [dir], reporting progress 0..1.
/// The app wires this to its engine (for example the Desert Ant bridge).
typedef SdkInstaller = Future<void> Function(String modelId, String sdkKey, String dir, void Function(double) progress);

/// Where the store lives on this device and who it is shared with.
class SharedLocation {
  const SharedLocation(this.path, this.scope, this.description);
  final String path;
  final ShareScope scope;

  /// Plain words for the settings page.
  final String description;
}

enum ShareScope {
  /// One folder used in place by every app of the vendor (iOS/macOS App Group, Windows, Linux).
  device,

  /// Each app keeps a copy, but copies from a sibling app instead of the network (Android).
  siblingCopy,

  /// The browser's cache, shared by every app served from the same origin (web).
  browser,

  /// Fallback: this app only (no App Group entitlement, for example).
  appOnly,
}
