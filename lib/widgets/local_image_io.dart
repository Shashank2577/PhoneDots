import 'dart:io';

import 'package:flutter/material.dart';

Widget localImage(String path, {double? width, double? height, BoxFit fit = BoxFit.cover}) => Image.file(
  File(path),
  width: width,
  height: height,
  fit: fit,
  cacheWidth: 600,
  errorBuilder: (_, _, _) => SizedBox(width: width, height: height, child: const Icon(Icons.broken_image_outlined)),
);
