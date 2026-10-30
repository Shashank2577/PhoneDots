import 'package:flutter/material.dart';

import 'local_image_io.dart' if (dart.library.js_interop) 'local_image_web.dart' as impl;

/// Thumbnail for a local file path; a placeholder where files are not
/// readable (web preview).
Widget localImage(String path, {double? width, double? height, BoxFit fit = BoxFit.cover}) =>
    impl.localImage(path, width: width, height: height, fit: fit);
