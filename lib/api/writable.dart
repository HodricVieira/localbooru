part of localbooru_api;

Future<void>? _activeWrite;

Future<T> _enqueueWrite<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final Future<void> prev = _activeWrite ?? Future<void>.value();
    late final Future<void> next;
    next = Zone.root.run(() {
        return prev.catchError((_) {}).then((_) async {
            try {
                final result = await action();
                completer.complete(result);
            } catch (e, st) {
                completer.completeError(e, st);
            } finally {
                if (identical(_activeWrite, next)) {
                    _activeWrite = null;
                }
            }
        });
    });
    _activeWrite = next;
    return completer.future;
}

Future writeSettings(String path, Map raw, {bool notify = true}) async {
    await _enqueueWrite(() async {
        final String encoded = const JsonEncoder.withIndent('  ').convert(raw);
        final File targetFile = File(p.join(path, "repoinfo.json"));
        final File tempFile = File(p.join(path, "repoinfo.json.tmp"));
        try {
            await tempFile.writeAsString(encoded, flush: true);
            await tempFile.rename(targetFile.path);
        } catch (_) {
            await targetFile.writeAsString(encoded, flush: true);
            if (await tempFile.exists()) {
                try { await tempFile.delete(); } catch (_) {}
            }
        }
    });
    if(notify) booruUpdateListener.update();
}

String _baseNameWithoutExtFromRel(String relFilename) {
    final normalized = relFilename.replaceAll('\\', '/');
    final base = normalized.split('/').last;
    return p.basenameWithoutExtension(base);
}

Future<void> deleteImageThumbnailFile(String booruPath, String imageId, String filename) async {
    final String base = _baseNameWithoutExtFromRel(filename);
    final String thumbDirPath = p.join(booruPath, "thumbnails");
    final File thumbFile = File(p.join(thumbDirPath, "${imageId}_$base.jpg"));
    final File legacyThumbFile = File(p.join(thumbDirPath, "$base.jpg"));

    for (final file in [thumbFile, legacyThumbFile]) {
        try {
            PaintingBinding.instance.imageCache.evict(FileImage(file));
        } catch (_) {}
        try {
            if (await file.exists()) {
                await file.delete();
            }
        } catch (_) {}
    }
}

Future<void> syncThumbnailsWithFiles(String booruPath, Map<String, String> oldToNewId, List<dynamic> currentFiles) async {
    final Directory thumbDir = Directory(p.join(booruPath, "thumbnails"));
    if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
    }

    final Map<String, String> newToOldId = {
        for (final entry in oldToNewId.entries) entry.value: entry.key,
    };

    // Phase 1: Rename old thumbnails to temporary names so shifting IDs never collide
    for (final rawFile in currentFiles) {
        final Map file = rawFile as Map;
        final String newId = file["id"].toString();
        final String base = _baseNameWithoutExtFromRel(file["filename"].toString());
        final String? oldId = newToOldId[newId];
        if (oldId != null && oldId != newId) {
            final File oldThumb = File(p.join(thumbDir.path, "${oldId}_$base.jpg"));
            final File tmpThumb = File(p.join(thumbDir.path, ".tmp_${newId}_$base.jpg"));
            if (await oldThumb.exists()) {
                try {
                    PaintingBinding.instance.imageCache.evict(FileImage(oldThumb));
                } catch (_) {}
                try {
                    await oldThumb.rename(tmpThumb.path);
                } catch (_) {}
            }
        }
    }

    // Phase 2: Move temporary thumbnails to their final newId names
    for (final rawFile in currentFiles) {
        final Map file = rawFile as Map;
        final String newId = file["id"].toString();
        final String base = _baseNameWithoutExtFromRel(file["filename"].toString());
        final File tmpThumb = File(p.join(thumbDir.path, ".tmp_${newId}_$base.jpg"));
        final File targetThumb = File(p.join(thumbDir.path, "${newId}_$base.jpg"));
        if (await tmpThumb.exists()) {
            try {
                PaintingBinding.instance.imageCache.evict(FileImage(targetThumb));
            } catch (_) {}
            if (await targetThumb.exists()) {
                try { await targetThumb.delete(); } catch (_) {}
            }
            try {
                await tmpThumb.rename(targetThumb.path);
            } catch (_) {}
        }
    }

    // Phase 3: Remove any orphaned thumbnails not matching current files
    final Set<String> validThumbNames = {
        ".nomedia",
        for (final rawFile in currentFiles)
            "${(rawFile as Map)["id"]}_${_baseNameWithoutExtFromRel(rawFile["filename"].toString())}.jpg",
    };
    await for (final entity in thumbDir.list()) {
        if (entity is File) {
            final String name = p.basename(entity.path);
            if (!validThumbNames.contains(name)) {
                try {
                    PaintingBinding.instance.imageCache.evict(FileImage(entity));
                } catch (_) {}
                try {
                    await entity.delete();
                } catch (_) {}
            }
        }
    }
}

Map<String, dynamic> rebase(Map<String, dynamic> raw) {
    // check all files
    if(raw["files"] == null) raw["files"] = List.from(defaultFileInfoJson["files"]);
    final List files = List.from(raw["files"]);
    final Map<String, String> oldToNewId = {};
    for(var (int index, dynamic rawFile) in files.indexed) {
        final Map<String, dynamic> file = Map<String, dynamic>.from(rawFile as Map);
        final String? oldId = file["id"]?.toString();
        final String newId = index.toString();
        if (oldId != null && oldId.isNotEmpty) {
            oldToNewId[oldId] = newId;
        }
        //recount all ids
        file["id"] = newId;

        file["tags"] = (file["tags"] ?? "").toString().split(" ")
            .where((tag) => tag.isNotEmpty // remove empty spaces
				&& !Metatag.isMetatag(tag) //remove any metatags on the tags
			)
            .join(" ");

        files[index] = file;
    }
    for (var (int index, dynamic rawFile) in files.indexed) {
        final Map<String, dynamic> file = Map<String, dynamic>.from(rawFile as Map);
        file["related"] = (file["related"] ?? [])
            .map((e) {
                final key = e.toString();
                if (oldToNewId.isNotEmpty) return oldToNewId[key];
                final parsed = int.tryParse(key);
                return (parsed != null && parsed >= 0 && parsed < files.length) ? key : null;
            })
            .whereType<String>()
            .where((targetId) => targetId != file["id"])
            .toSet()
            .toList();
        files[index] = file;
    }
    raw["files"] = files;

    // check specific tags
    if(raw["specificTags"] == null) {
        raw["specificTags"] = Map<String, dynamic>.from(defaultFileInfoJson["specificTags"]);
    } else {
        // clean empty types
        for (final type in raw["specificTags"].keys) {
            List<String> contents = List.from(raw["specificTags"][type]);
            contents = contents.where((e) => e.isNotEmpty).toList();
            raw["specificTags"][type] = contents;
        }
    }

    // check collections
    if(raw["collections"] == null) {
        raw["collections"] = List.from(defaultFileInfoJson["collections"]);
    } else {
        final List<Map<String, dynamic>> collections = List<Map<String, dynamic>>.from(
            (raw["collections"] as List).map((e) => Map<String, dynamic>.from(e as Map))
        );
        for (var (index, collection) in collections.indexed) {
            //recount collections
            collection["id"] = index.toString();
            if (collection["pages"] is List) {
                collection["pages"] = (collection["pages"] as List)
                    .map((e) {
                        final key = e.toString();
                        if (oldToNewId.isNotEmpty) return oldToNewId[key];
                        if (files.isEmpty) return null;
                        final parsed = int.tryParse(key);
                        return (parsed != null && parsed >= 0 && parsed < files.length) ? key : null;
                    })
                    .whereType<String>()
                    .toSet()
                    .toList();
            }

            collections[index] = collection;
        }
        raw["collections"] = collections;
    }

    return raw;
}



String sanitizeCollectionFolderName(String rawName) {
    final sanitized = rawName
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    return sanitized.isEmpty ? "collection" : sanitized;
}

Future<BooruImage> insertImage(PresetImage preset, {bool notify = true, bool? moveFile, String? targetSubfolder}) async {
    final Booru booru = await getCurrentBooru();

    if(preset.image is! File) throw "Preset does not contain a file";

    final bool shouldMove = moveFile ?? ((await SharedPreferences.getInstance()).getString("file_import_mode") == "move");
    final String booruFilesRoot = p.join(booru.path, "files");
    final String? cleanSubfolder = (targetSubfolder != null && targetSubfolder.trim().isNotEmpty)
        ? sanitizeCollectionFolderName(targetSubfolder)
        : null;
    final String destDir = cleanSubfolder != null
        ? p.join(booruFilesRoot, cleanSubfolder)
        : booruFilesRoot;
    await Directory(destDir).create(recursive: true);

    final File currentSourceFile = preset.image!;
    final File? originalSourceFile = preset.originalImage;
    final String sourcePath = currentSourceFile.path;
    final String targetPath = p.join(destDir, p.basename(sourcePath));

    // step 1: copy or move image
    File copiedFile;
    if (p.equals(p.dirname(sourcePath), destDir) ||
        (cleanSubfolder == null && preset.replaceID != null && p.isWithin(booruFilesRoot, sourcePath))) {
        debugPrint("here, ${p.dirname(sourcePath)} $destDir");
        copiedFile = currentSourceFile;
    } else {
        copiedFile = await currentSourceFile.copy(targetPath);
        final bool isMovingExistingWithinBooru = p.isWithin(booruFilesRoot, sourcePath);
        final bool isSourceOutsideBooru = !isMovingExistingWithinBooru && !p.equals(booruFilesRoot, sourcePath);
        if ((shouldMove && isSourceOutsideBooru) || isMovingExistingWithinBooru) {
            if (await copiedFile.exists() && await copiedFile.length() > 0) {
                preset.image = copiedFile;
                preset.originalImage = copiedFile;

                if (!p.equals(sourcePath, targetPath)) {
                    final deleted = await deleteSourceFileAfterMove(
                        currentSourceFile,
                        targetPath: copiedFile.path,
                    );
                    if (!deleted) {
                        debugPrint("Failed to delete source file after moving ($sourcePath)");
                    }
                }
                final origPath = originalSourceFile?.path;
                if (originalSourceFile != null &&
                    origPath != null &&
                    !p.equals(origPath, sourcePath) &&
                    !p.equals(origPath, targetPath) &&
                    !p.isWithin(booruFilesRoot, origPath)) {
                    final deletedOrig = await deleteSourceFileAfterMove(
                        originalSourceFile,
                        targetPath: copiedFile.path,
                    );
                    if (!deletedOrig) {
                        debugPrint("Failed to delete original uncompressed file after moving ($origPath)");
                    }
                }
            }
        }
    }

    // step 2: add tag types
    if(preset.tags == null) throw "Preset does not contain tags";
    Set<String> tagSet = {};
    for (MapEntry<String, List<String>> tagType in preset.tags!.entries) {
        if(tagType.value.isNotEmpty) {
            tagSet.addAll(tagType.value); //you can add values to sets
            if(tagType.key != "generic") await addSpecificTags(tagType.value, type: tagType.key, notify: false);
        }
    }

    // step 3: adding to json
    // obtain raw AFTER adding specific tags
    Map raw = await booru.getRawInfo();
    List files = raw["files"];

    // determine id
    String id = preset.replaceID == null || int.parse(preset.replaceID!) > files.length ? "${files.length}" : preset.replaceID!;
    
    // determine rating
    final String? ratingString = switch(preset.rating) {
        Rating.safe => "safe",
        Rating.questionable => "questionable",
        Rating.explicit => "explicit",
        Rating.illegal => "illegal",
        _ => null
    };

    final String relativeFilename = p.relative(copiedFile.path, from: booruFilesRoot).replaceAll('\\', '/');

    // map to push
    Map toPush = {
        "id": id,
        "filename": relativeFilename,
        "tags": tagSet.join(" "),
        if(ratingString != null) "rating": ratingString,
        "sources": preset.sources ?? [],
        "related": preset.relatedImages ?? [],
        if(preset.note != null && preset.note!.isNotEmpty) "note": preset.note
    };
    
    // find if inputed id already exists, and if no add to its latest index, otherwise replace element on that id
    int index = files.indexWhere((e) => e["id"] == id);
    if (index < 0) files.add(toPush);
    else files[index] = toPush;

    raw["files"] = files;

    await writeSettings(booru.path, raw, notify: notify);

    return (await booru.getImage(id))!;
}

Future<void> writeSpecificTags(Map<String, List<String>> specificTags, {bool notify = true}) async {
    final Booru booru = await getCurrentBooru();

    // add to json
    var raw = await booru.getRawInfo();
    raw["specificTags"] = specificTags;

    await writeSettings(booru.path, raw, notify: notify);
}

Future<void> addSpecificTags(List<String> tags, {required String type, bool notify = true}) async {
    final Booru booru = await getCurrentBooru();

    // add to json
    var raw = await booru.getRawInfo();
    final specificTagsList = raw["specificTags"][type];
    List<String> specificTags = List<String>.from(specificTagsList ?? []);

    for(String tag in tags) {
        if(!specificTags.contains(tag)) specificTags.add(tag);
    }

    raw["specificTags"][type] = specificTags;

    Map<String, List<String>> iLoveDartsTypeSystem = {};
    for(MapEntry entry in raw["specificTags"].entries) {
        iLoveDartsTypeSystem[entry.key] = List<String>.from(entry.value);
    }

    // debugPrint("before ${raw["specificTags"]} after $iLoveDartsTypeSystem");

    await writeSpecificTags(iLoveDartsTypeSystem, notify: notify);
}

Future<void> removeImages(List<ImageID> ids, {bool notify = true}) async {
    if (ids.isEmpty) return;
    final Booru booru = await getCurrentBooru();
    var raw = await booru.getRawInfo();
    final List files = List.from(raw["files"] ?? []);
    final Set<String> idSet = ids.map((e) => e.toString()).toSet();

    final List<Map> toDelete = files
        .where((e) => idSet.contains(e["id"].toString()))
        .cast<Map>()
        .toList();

    if (toDelete.isEmpty) {
        if (ids.length == 1) throw "Image ${ids.first} does not exist";
        return;
    }

    files.removeWhere((e) => idSet.contains(e["id"].toString()));

    final Map<String, String> oldToNewId = {
        for (var (int index, dynamic f) in files.indexed)
            if ((f as Map)["id"] != null && f["id"].toString().isNotEmpty)
                f["id"].toString(): index.toString(),
    };

    for (final fileMap in toDelete) {
        final String oldId = fileMap["id"].toString();
        final String rawRel = fileMap["filename"].toString().replaceAll('\\', '/');
        final List<String> segments = rawRel.split('/').where((s) => s.isNotEmpty).toList();
        final File imageFile = File(p.joinAll([booru.path, "files", ...segments]));
        try {
            PaintingBinding.instance.imageCache.evict(FileImage(imageFile));
        } catch (_) {}
        if (await imageFile.exists()) {
            await imageFile.delete();
        }
        await deleteImageThumbnailFile(booru.path, oldId, rawRel);
    }

    raw["files"] = files;
    raw = rebase(raw);

    await syncThumbnailsWithFiles(booru.path, oldToNewId, raw["files"]);
    await writeSettings(booru.path, raw, notify: notify);
}

Future removeImage(String id, {bool notify = true}) => removeImages([id], notify: notify);



Future<BooruCollection> insertCollection(PresetCollection preset, {bool notify = true}) async {
    final Booru booru = await getCurrentBooru();

    if(preset.pages is! List<String>) throw "Preset does not contain pages";
    if(preset.name == null) throw "Preset does not contain a name";

    Map raw = await booru.getRawInfo();
    List<Map<String, dynamic>> collections = List<Map<String, dynamic>>.from(raw["collections"]);
    List files = raw["files"];

    // determine id
    String id = preset.id == null || int.parse(preset.id!) > collections.length ? "${collections.length}" : preset.id!;

    final String booruFilesRoot = p.join(booru.path, "files");
    final String folderName = sanitizeCollectionFolderName(preset.name!);
    final Directory collectionDir = Directory(p.join(booruFilesRoot, folderName));
    if (!await collectionDir.exists()) {
        await collectionDir.create(recursive: true);
    }

    int index = collections.indexWhere((e) => e["id"] == id);
    if (index >= 0) {
        final List<String> oldPages = List<String>.from(collections[index]["pages"] ?? []);
        final String? oldName = collections[index]["name"]?.toString();
        final String? oldFolder = (collections[index]["folder"]?.toString().trim().isNotEmpty == true)
            ? collections[index]["folder"].toString()
            : (oldName != null ? sanitizeCollectionFolderName(oldName) : null);
        if (oldFolder != null && oldFolder != folderName) {
            final oldDir = Directory(p.join(booruFilesRoot, oldFolder));
            if (await oldDir.exists()) {
                for (var i = 0; i < files.length; i++) {
                    final String rel = files[i]["filename"].toString().replaceAll('\\', '/');
                    if (rel.startsWith("$oldFolder/")) {
                        final String base = p.basename(rel);
                        final File oldFile = File(p.join(oldDir.path, base));
                        final File newFile = File(p.join(collectionDir.path, base));
                        if (await oldFile.exists()) {
                            await oldFile.copy(newFile.path);
                            if (await newFile.exists() && await newFile.length() > 0) {
                                try { await oldFile.delete(); } catch (_) {}
                            }
                        }
                        files[i]["filename"] = "$folderName/$base";
                    }
                }
                try {
                    if (await oldDir.list().isEmpty) {
                        await oldDir.delete();
                    }
                } catch (_) {}
            }
        }
        // Any image removed from this collection moves back to root booru/files
        for (final String removedId in oldPages.where((pId) => !preset.pages!.contains(pId))) {
            final int fileIdx = files.indexWhere((f) => f["id"].toString() == removedId.toString());
            if (fileIdx < 0) continue;
            final String currentRel = files[fileIdx]["filename"].toString().replaceAll('\\', '/');
            if (currentRel.startsWith("$folderName/")) {
                final String base = p.basename(currentRel);
                final File currentFile = File(p.join(collectionDir.path, base));
                final File rootFile = File(p.join(booruFilesRoot, base));
                if (await currentFile.exists()) {
                    await currentFile.copy(rootFile.path);
                    if (await rootFile.exists() && await rootFile.length() > 0) {
                        try { await currentFile.delete(); } catch (_) {}
                        files[fileIdx]["filename"] = base;
                    }
                }
            }
        }
    }

    // Move all images belonging to this collection into its folder
    for (final String imageId in preset.pages!) {
        final int fileIdx = files.indexWhere((f) => f["id"].toString() == imageId.toString());
        if (fileIdx < 0) continue;
        final String currentRel = files[fileIdx]["filename"].toString().replaceAll('\\', '/');
        final List<String> segments = currentRel.split('/').where((s) => s.isNotEmpty).toList();
        final File currentFile = File(p.joinAll([booruFilesRoot, ...segments]));
        final String baseName = p.basename(currentFile.path);
        final String targetRel = "$folderName/$baseName";
        final File targetFile = File(p.join(collectionDir.path, baseName));

        if (currentRel != targetRel && await currentFile.exists()) {
            await currentFile.copy(targetFile.path);
            if (await targetFile.exists() && await targetFile.length() > 0) {
                try {
                    if (!p.equals(currentFile.path, targetFile.path)) {
                        await currentFile.delete();
                    }
                } catch (_) {}
                files[fileIdx]["filename"] = targetRel;
            }
        } else if (await targetFile.exists()) {
            files[fileIdx]["filename"] = targetRel;
        }
    }

    // map to push
    Map<String, dynamic> toPush = {
        "id": id,
        "pages": preset.pages,
        "name": preset.name,
        "folder": folderName,
    };
    
    // find if inputed id already exists, and if no add to its latest index, otherwise replace element on that id
    if (index < 0) collections.add(toPush);
    else collections[index] = toPush;

    raw["files"] = files;
    raw["collections"] = collections;

    await writeSettings(booru.path, raw, notify: notify);

    return (await booru.getCollection(id))!;
}

Future<BooruCollection> addImagesToCollection(CollectionID collectionId, List<ImageID> imageIds, {bool notify = true}) async {
    final Booru booru = await getCurrentBooru();
    final BooruCollection? existing = await booru.getCollection(collectionId);
    if (existing == null) throw "Collection $collectionId does not exist";

    final List<ImageID> mergedPages = List<ImageID>.from(existing.pages);
    for (final imgId in imageIds) {
        if (!mergedPages.contains(imgId)) {
            mergedPages.add(imgId);
        }
    }
    return await insertCollection(
        PresetCollection(
            id: existing.id,
            name: existing.name,
            pages: mergedPages,
        ),
        notify: notify,
    );
}

Future removeCollection(CollectionID id, {bool notify = true, bool deleteContent = false}) async {
    final Booru booru = await getCurrentBooru();
    final collection = await booru.getCollection(id);
    if(collection == null) throw "Collection $id does not exist";

    var raw = await booru.getRawInfo();
    final List collections = List.from(raw["collections"] ?? []);
    final List files = List.from(raw["files"] ?? []);

    final String booruFilesRoot = p.join(booru.path, "files");
    final String folderName = collection.folder ?? sanitizeCollectionFolderName(collection.name);
    final Directory collectionDir = Directory(p.join(booruFilesRoot, folderName));

    bool belongsToCollection(dynamic rawFile) {
        final Map f = rawFile as Map;
        final String fId = f["id"].toString();
        final String currentRel = f["filename"].toString().replaceAll('\\', '/');
        return collection.pages.contains(fId) || currentRel.startsWith("$folderName/");
    }

    if (deleteContent) {
        final List<Map> filesToDelete = files.where(belongsToCollection).cast<Map>().toList();

        for (final fileMap in filesToDelete) {
            final String oldId = fileMap["id"].toString();
            final String rawRel = fileMap["filename"].toString().replaceAll('\\', '/');
            final List<String> segments = rawRel.split('/').where((s) => s.isNotEmpty).toList();
            final File imageFile = File(p.joinAll([booruFilesRoot, ...segments]));
            try {
                PaintingBinding.instance.imageCache.evict(FileImage(imageFile));
            } catch (_) {}
            if (await imageFile.exists()) {
                await imageFile.delete();
            }
            await deleteImageThumbnailFile(booru.path, oldId, rawRel);
        }

        files.removeWhere(belongsToCollection);

        final Map<String, String> oldToNewId = {
            for (var (int index, dynamic f) in files.indexed)
                if ((f as Map)["id"] != null && f["id"].toString().isNotEmpty)
                    f["id"].toString(): index.toString(),
        };

        if (await collectionDir.exists()) {
            await collectionDir.delete(recursive: true);
        }

        collections.removeWhere((e) => e["id"].toString() == id.toString());
        raw["files"] = files;
        raw["collections"] = collections;
        raw = rebase(raw);

        await syncThumbnailsWithFiles(booru.path, oldToNewId, raw["files"]);
        await writeSettings(booru.path, raw, notify: notify);
    } else {
        // Move images from the deleted collection folder back to the root booru/files directory
        for (int fileIdx = 0; fileIdx < files.length; fileIdx++) {
            final Map f = Map<String, dynamic>.from(files[fileIdx] as Map);
            if (!belongsToCollection(f)) continue;
            final String currentRel = f["filename"].toString().replaceAll('\\', '/');
            if (currentRel.startsWith("$folderName/")) {
                final String baseName = currentRel.split('/').last;
                final File currentFile = File(p.join(collectionDir.path, baseName));
                File rootFile = File(p.join(booruFilesRoot, baseName));
                if (await rootFile.exists() && !p.equals(currentFile.path, rootFile.path)) {
                    final String stem = p.basenameWithoutExtension(baseName);
                    final String ext = p.extension(baseName);
                    rootFile = File(p.join(booruFilesRoot, "${stem}_${f["id"]}$ext"));
                    int suffix = 1;
                    while (await rootFile.exists()) {
                        rootFile = File(p.join(booruFilesRoot, "${stem}_${f["id"]}_$suffix$ext"));
                        suffix++;
                    }
                }
                if (await currentFile.exists()) {
                    await currentFile.copy(rootFile.path);
                    final int origLen = await currentFile.length();
                    if (await rootFile.exists() && (await rootFile.length() > 0 || origLen == 0)) {
                        try {
                            PaintingBinding.instance.imageCache.evict(FileImage(currentFile));
                        } catch (_) {}
                        try { await currentFile.delete(); } catch (_) {}
                        final String newBaseName = p.basename(rootFile.path);
                        if (newBaseName != baseName) {
                            final String oldThumbName = "${f["id"]}_${p.basenameWithoutExtension(baseName)}.jpg";
                            final String newThumbName = "${f["id"]}_${p.basenameWithoutExtension(newBaseName)}.jpg";
                            final File oldThumb = File(p.join(booru.path, "thumbnails", oldThumbName));
                            final File newThumb = File(p.join(booru.path, "thumbnails", newThumbName));
                            if (await oldThumb.exists()) {
                                try { await oldThumb.rename(newThumb.path); } catch (_) {}
                            }
                        }
                        f["filename"] = newBaseName;
                        files[fileIdx] = f;
                    }
                }
            }
        }
        try {
            if (await collectionDir.exists()) {
                final File nomedia = File(p.join(collectionDir.path, ".nomedia"));
                if (await nomedia.exists()) {
                    try { await nomedia.delete(); } catch (_) {}
                }
                if (await collectionDir.list().isEmpty) {
                    await collectionDir.delete();
                }
            }
        } catch (_) {}

        collections.removeWhere((e) => e["id"].toString() == id.toString());
        raw["files"] = files;
        raw["collections"] = collections;

        await writeSettings(booru.path, rebase(raw), notify: notify);
    }
}