/// Where a test writes its scratch files: `ztmp/` of the workspace this
/// package is checked out in (the nearest ancestor holding `.tom_metadata`),
/// or `.dart_tool/scratch/` of the package when it stands alone.
library;

import 'dart:io';

/// A fresh directory for [name], under the workspace's `ztmp/`.
Directory scratchDirectory(String name) {
  var dir = Directory.current.absolute;
  while (true) {
    if (Directory('${dir.path}/.tom_metadata').existsSync()) {
      return Directory('${dir.path}/ztmp/tom_core_sync/$name')
        ..createSync(recursive: true);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('${Directory.current.path}/.dart_tool/scratch/$name')
    ..createSync(recursive: true);
}
