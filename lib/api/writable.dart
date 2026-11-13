part of localbooru_api;

Future writeSettings(String path, Map raw, {bool notify = true}) async {
    await File(p.join(path, "repoinfo.json")).writeAsString(const JsonEncoder.withIndent('  ').convert(raw));
    if(notify) booruUpdateListener.update();
}

Map<String, dynamic> rebase(Map<String, dynamic> raw) {
    // check all files
    if(raw["files"] == null) raw["files"] = defaultFileInfoJson["files"];
    List files = raw["files"];
    for(var (int index, Map file) in files.indexed) {
        //recount all ids
        file["id"] = index.toString();

        file["tags"] = (file["tags"] as String).split(" ")
            .where((tag) => tag.isNotEmpty // remove empty spaces
				&& !Metatag.isMetatag(tag) //remove any metatags on the tags
			)
            .join(" ");
        file["related"] = (file["related"] ?? []).where((e) => int.tryParse(e) != null && files.elementAtOrNull(int.parse(e)) != null).toList();

        files[index] = file as dynamic;
    }
    raw["files"] = files;

    // check specific tags
    if(raw["specificTags"] == null) {
        raw["specificTags"] = defaultFileInfoJson["specificTags"];
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
        raw["collections"] = defaultFileInfoJson["collections"];
    } else {
        final List<Map<String, dynamic>> collections = List<Map<String, dynamic>>.from(raw["collections"]);
        for (var (index, collection) in collections.indexed) {
            //recount collections
            collection["id"] = index.toString();

            raw["collections"][index] = collection;
        }
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

    final String sourcePath = preset.image!.path;
    final String targetPath = p.join(destDir, p.basename(sourcePath));

    // step 1: copy or move image
    File copiedFile;
    if (p.equals(p.dirname(sourcePath), destDir) ||
        (cleanSubfolder == null && preset.replaceID != null && p.isWithin(booruFilesRoot, sourcePath))) {
        debugPrint("here, ${p.dirname(sourcePath)} $destDir");
        copiedFile = preset.image!;
    } else {
        copiedFile = await preset.image!.copy(targetPath);
        final bool isMovingExistingWithinBooru = p.isWithin(booruFilesRoot, sourcePath);
        if ((shouldMove && preset.replaceID == null) || isMovingExistingWithinBooru) {
            if (await copiedFile.exists() && await copiedFile.length() > 0) {
                try {
                    if (!p.equals(sourcePath, targetPath) && await preset.image!.exists()) {
                        await preset.image!.delete();
                    }
                } catch (e) {
                    debugPrint("Failed to delete source file after moving ($sourcePath): $e");
                }
                final origPath = preset.originalImage?.path;
                if (origPath != null &&
                    !p.equals(origPath, sourcePath) &&
                    !p.equals(origPath, targetPath) &&
                    !p.isWithin(booruFilesRoot, origPath)) {
                    try {
                        if (await preset.originalImage!.exists()) {
                            await preset.originalImage!.delete();
                        }
                    } catch (e) {
                        debugPrint("Failed to delete original uncompressed file after moving ($origPath): $e");
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

Future removeImage(String id, {bool notify = true}) async {
    final Booru booru = await getCurrentBooru();
    final BooruImage? image = await booru.getImage(id);
    if(image == null) throw "Image $id does not exist";
    final file = File(image.path);

    // remove file association
    var raw = await booru.getRawInfo();
    List files = raw["files"];

    files.removeWhere((e) => e["id"] == id);
    raw["files"] = files;
    
    await writeSettings(booru.path, rebase(raw), notify: notify);

    // remove file
    await file.delete();

}



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

Future removeCollection(CollectionID id, {bool notify = true}) async {
    final Booru booru = await getCurrentBooru();
    final collection = await booru.getCollection(id);
    if(collection == null) throw "Collection $id does not exist";

    var raw = await booru.getRawInfo();
    List collections = raw["collections"];
    List files = raw["files"];

    final String booruFilesRoot = p.join(booru.path, "files");
    final String folderName = collection.folder ?? sanitizeCollectionFolderName(collection.name);
    final Directory collectionDir = Directory(p.join(booruFilesRoot, folderName));

    // Move images from the deleted collection folder back to the root booru/files directory
    for (final String imageId in collection.pages) {
        final int fileIdx = files.indexWhere((f) => f["id"].toString() == imageId.toString());
        if (fileIdx < 0) continue;
        final String currentRel = files[fileIdx]["filename"].toString().replaceAll('\\', '/');
        if (currentRel.startsWith("$folderName/")) {
            final String baseName = p.basename(currentRel);
            final File currentFile = File(p.join(collectionDir.path, baseName));
            final File rootFile = File(p.join(booruFilesRoot, baseName));
            if (await currentFile.exists()) {
                await currentFile.copy(rootFile.path);
                if (await rootFile.exists() && await rootFile.length() > 0) {
                    try { await currentFile.delete(); } catch (_) {}
                    files[fileIdx]["filename"] = baseName;
                }
            }
        }
    }
    try {
        if (await collectionDir.exists() && await collectionDir.list().isEmpty) {
            await collectionDir.delete();
        }
    } catch (_) {}

    collections.removeWhere((e) => e["id"] == id);
    raw["files"] = files;
    raw["collections"] = collections;
    
    await writeSettings(booru.path, rebase(raw), notify: notify);

}