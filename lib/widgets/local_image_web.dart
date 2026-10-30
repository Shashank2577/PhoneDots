import 'package:flutter/material.dart';

Widget localImage(String path, {double? width, double? height, BoxFit fit = BoxFit.cover}) => Image.network(
  path,
  width: width,
  height: height,
  fit: fit,
  errorBuilder: (_, _, _) => SizedBox(width: width, height: height, child: const Icon(Icons.image_outlined)),
);
