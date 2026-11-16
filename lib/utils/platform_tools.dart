

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

const MethodChannel _storageChannel = MethodChannel("com.auser.localbooru/storage");

bool isDesktop() {
    return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}

bool isMobile() {
    return Platform.isAndroid || Platform.isIOS;
}

bool isApple() {
    return Platform.isMacOS || Platform.isIOS;
}

bool hasWindowFrameNavigation() {
    return isDesktop();
}

/// Picks media files (images/videos) returning their real filesystem paths on Android
/// instead of temporary copies inside the app's cache directory.
Future<List<File>?> pickMediaFilesWithRealPaths() async {
    if (Platform.isAndroid) {
        try {
            final List<String>? paths = await _storageChannel.invokeListMethod<String>("pickMediaFiles");
            if (paths == null) return null;
            return paths.where((p) => p.isNotEmpty).map((p) => File(p)).toList();
        } on MissingPluginException {
            // Fallback in test/non-native environments
        } catch (_) {}
    }
    final FilePickerResult? pickerResult = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: true,
    );
    return pickerResult?.files
        .where((file) => file.path != null && file.path!.isNotEmpty)
        .map((file) => File(file.path!))
        .toList();
}

/// Picks a directory path, preserving SAF tree write/delete permissions on Android.
Future<String?> pickDirectoryWithRealPath() async {
    if (Platform.isAndroid) {
        try {
            final String? dirPath = await _storageChannel.invokeMethod<String>("pickDirectory");
            if (dirPath != null && dirPath.isNotEmpty) return dirPath;
            if (dirPath == null) return null;
        } on MissingPluginException {
            // Fallback in test/non-native environments
        } catch (_) {}
    }
    return await FilePicker.platform.getDirectoryPath();
}

void evictFileFromImageCache(File file) {
    try {
        final provider = FileImage(file);
        provider.evict();
        ResizeImage(provider, width: 400).evict();
        ResizeImage(provider, height: 400).evict();
        ResizeImage(provider, width: 200).evict();
        ResizeImage(provider, height: 200).evict();
    } catch (_) {}
}

/// Deletes a source file after it has been copied to [targetPath] in Move mode.
/// Handles image cache eviction, Android SAF/MediaStore deletion + MediaScanner refresh,
/// and retries on transient OS file lock contention.
Future<bool> deleteSourceFileAfterMove(File sourceFile, {String? targetPath}) async {
    evictFileFromImageCache(sourceFile);

    if (Platform.isAndroid) {
        try {
            final bool? deletedNatively = await _storageChannel.invokeMethod<bool>(
                "deleteSourceFile",
                {
                    "sourcePath": sourceFile.path,
                    "targetPath": targetPath,
                },
            );
            if (deletedNatively == true && !(await sourceFile.exists())) {
                return true;
            }
        } on MissingPluginException {
            // Ignore in unit test environments
        } catch (_) {}
    }

    for (int attempt = 0; attempt < 3; attempt++) {
        try {
            if (!await sourceFile.exists()) return true;
            await sourceFile.delete();
            if (!await sourceFile.exists()) return true;
        } catch (_) {
            if (attempt < 2) {
                await Future.delayed(const Duration(milliseconds: 60));
                evictFileFromImageCache(sourceFile);
            }
        }
    }
    return !(await sourceFile.exists());
}

/// Deletes an empty source directory after moving all its media files.
Future<bool> deleteEmptySourceDirectoryAfterMove(Directory sourceDir) async {
    if (Platform.isAndroid) {
        try {
            final bool? deletedNatively = await _storageChannel.invokeMethod<bool>(
                "deleteEmptyDirectory",
                {"folderPath": sourceDir.path},
            );
            if (deletedNatively == true && !(await sourceDir.exists())) {
                return true;
            }
        } on MissingPluginException {
            // Ignore in unit test environments
        } catch (_) {}
    }

    try {
        if (!await sourceDir.exists()) return true;
        final entries = await sourceDir.list().toList();
        const trivialNames = {".nomedia", "thumbs.db", ".ds_store", "desktop.ini"};
        final bool allTrivial = entries.every(
            (e) => e is File && trivialNames.contains(e.uri.pathSegments.last.toLowerCase()),
        );
        if (entries.isNotEmpty && allTrivial) {
            for (final e in entries) {
                try {
                    await e.delete();
                } catch (_) {}
            }
        }
        if (await sourceDir.list().isEmpty) {
            await sourceDir.delete();
        }
    } catch (_) {}
    return !(await sourceDir.exists());
}