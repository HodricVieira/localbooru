
part of localbooru_api;

// ignore: non_constant_identifier_names
final int INDEX_IMAGE_LIMIT = settingsDefaults["page_size"];

class Booru {
    Booru(this.path);
    
    String path;

    Future<Map<String, dynamic>> getRawInfo() async {
        final activeWrite = _activeWrite;
        if (activeWrite != null) {
            try {
                await activeWrite;
            } catch (_) {}
        }

        final File file = File(p.join(path, "repoinfo.json"));
        final String fileinfo = await Zone.root.run(() => file.readAsString());
        Map<String, dynamic> json = jsonDecode(fileinfo);

        final List rawCollections = List.from(json["collections"] ?? []);
        if (rawCollections.isNotEmpty) {
            final String booruFilesRoot = p.join(path, "files");
            final List<Map<String, dynamic>> survivingCollections = [];
            final Set<String> deletedFolders = {};
            final Set<String> deletedCollectionPageIds = {};

            for (final rawCol in rawCollections) {
                final Map<String, dynamic> colMap = Map<String, dynamic>.from(rawCol as Map);
                final String? colFolderRaw = colMap["folder"]?.toString();
                final String colName = (colMap["name"] ?? "").toString();
                final String folderName = (colFolderRaw != null && colFolderRaw.trim().isNotEmpty)
                    ? colFolderRaw
                    : sanitizeCollectionFolderName(colName);
                final Directory colDir = Directory(p.join(booruFilesRoot, folderName));
                if (await colDir.exists()) {
                    survivingCollections.add(colMap);
                } else {
                    deletedFolders.add(folderName);
                    if (colMap["pages"] is List) {
                        for (final pageId in colMap["pages"]) {
                            deletedCollectionPageIds.add(pageId.toString());
                        }
                    }
                }
            }

            if (deletedFolders.isNotEmpty) {
                final List rawFiles = List.from(json["files"] ?? []);
                final List<Map<String, dynamic>> survivingFiles = [];

                for (final rawFile in rawFiles) {
                    final Map<String, dynamic> fMap = Map<String, dynamic>.from(rawFile as Map);
                    final String fileId = (fMap["id"] ?? "").toString();
                    final String rawRel = (fMap["filename"] ?? "").toString().replaceAll('\\', '/');
                    final bool belongsToDeletedFolder = deletedFolders.any((folder) => rawRel.startsWith("$folder/"))
                        || deletedCollectionPageIds.contains(fileId);

                    if (belongsToDeletedFolder) {
                        final List<String> relSegments = rawRel.split('/').where((s) => s.isNotEmpty).toList();
                        final File currentFile = File(p.joinAll([booruFilesRoot, ...relSegments]));
                        if (await currentFile.exists()) {
                            survivingFiles.add(fMap);
                        } else {
                            final String baseName = relSegments.isNotEmpty ? relSegments.last : rawRel;
                            final File rootFile = File(p.join(booruFilesRoot, baseName));
                            if (baseName.isNotEmpty && await rootFile.exists()) {
                                fMap["filename"] = baseName;
                                survivingFiles.add(fMap);
                            } else {
                                await deleteImageThumbnailFile(path, fileId, rawRel);
                            }
                        }
                    } else {
                        survivingFiles.add(fMap);
                    }
                }

                final Map<String, String> oldToNewId = {
                    for (var (int index, Map<String, dynamic> f) in survivingFiles.indexed)
                        if (f["id"] != null && f["id"].toString().isNotEmpty)
                            f["id"].toString(): index.toString(),
                };

                json["files"] = survivingFiles;
                json["collections"] = survivingCollections;
                json = rebase(json);
                await syncThumbnailsWithFiles(path, oldToNewId, json["files"]);
                await writeSettings(path, json, notify: false);
            }
        }

        return json;
    }
    Future<Map<String, dynamic>> rebaseRaw() async {
        return rebase(Map.from(await getRawInfo()));
    }

    BooruImage? _imageFromRawMap(Map fileToCheck) {
        final metadataToCheck = ["filename", "tags", "id"];
        for (String metadata in metadataToCheck) {
            if(!fileToCheck.containsKey(metadata)) throw "File ${fileToCheck["id"]} doesn't contain property $metadata";
        }

        final Rating? rating = switch(fileToCheck["rating"]) {
            "safe" => Rating.safe,
            "questionable" => Rating.questionable,
            "explicit" => Rating.explicit,
            "illegal" => Rating.illegal,
            _ => null
        };

        final String rawRel = fileToCheck["filename"].toString().replaceAll('\\', '/');
        final List<String> relSegments = rawRel.split('/').where((s) => s.isNotEmpty).toList();

        return BooruImage(
            id: fileToCheck["id"].toString(),
            path: p.joinAll([path, "files", ...relSegments]),
            tags: fileToCheck["tags"].toString(),
            rating: rating,
            note: fileToCheck["note"]?.toString(),
            sources: List<String>.from(fileToCheck["sources"] ?? []),
            relatedImages: List<String>.from(fileToCheck["related"] ?? []),
        );
    }

    Future<BooruImage?> getImage(String id) async {
        final List<Map<String, dynamic>> files = List<Map<String, dynamic>>.from((await getRawInfo())["files"]);
        
        var fileToCheck = files.firstWhereOrNull((file) => file["id"] == id);
        if(fileToCheck == null) return null;
        
        return _imageFromRawMap(fileToCheck);
    }



    Future<List<BooruImage>> getImagesFromRange(List list, {required int from, required int to}) async {
        final List rangedList = list.getRange(from, to).toList();

        List<BooruImage> mappedList = [];
        for (Map item in rangedList) {
            final img = _imageFromRawMap(item);
            if (img != null) mappedList.add(img);
        }
        return mappedList.reversed.toList();
    }
    Future<List<BooruImage>> getImagesFromIndex(List list, {int index = 0, int? size}) async {
        size ??= INDEX_IMAGE_LIMIT;

        final int length = list.length;

        int from = length - (size * (index + 1));
        int to = length - (size * index);
        if(from < 0) from = 0;
        if(to < 0) to = length;

        final List<BooruImage> range = await getImagesFromRange(list, from: from, to: to);

        return range;
    }
    Future<List<BooruImage>> getRecentImages() async => await getImagesFromIndex((await getRawInfo())["files"]);

    Future<List> _doTagFiltering(String tags) async {
        final List<SearchTag> tagList = tags.split(" ").where((s) => s.isNotEmpty).map((e) => SearchTag.fromText(e),).toList();
        final List files = (await getRawInfo())["files"];
        List filteredFiles = [];
        if(tagList.isEmpty) return files;
        for (final file in files) {
            if(await wouldImageBeSelected(tags: tagList, file: file)) filteredFiles.add(file);
        }

        return filteredFiles;
    }
    Future<List<BooruImage>> searchByTags(String tags, {int index = 0, int? size}) async => await getImagesFromIndex(await _doTagFiltering(tags), index: index, size: size);

    Future<int> getIndexNumberLength(tags, {int? size}) async {
        size ??= INDEX_IMAGE_LIMIT;

        final list = await _doTagFiltering(tags);

        return (list.length / size).ceil();
    }
    Future<int> getListLength([List? list]) async {
        list ??= (await getRawInfo())["files"];

        return list?.length ?? 0;
    }


    Future<List<BooruTagCounterDisplay<NormalTag>>> getAllTags() async {
        final List files = (await getRawInfo())["files"];
        List<BooruTagCounterDisplay<NormalTag>> allTags = List<BooruTagCounterDisplay<NormalTag>>.empty(growable: true);
        for (var file in files) {
            List<String> fileTags = file["tags"].split(" ");
            for (String tag in fileTags) {
                final tagInstance = allTags.indexWhere((element) => element.tag.getText() == tag,);
                if(tagInstance < 0) {
                    allTags.add(BooruTagCounterDisplay(tag: NormalTag(tag), callQuantity: 1));
                } else {
                    allTags[tagInstance].callQuantity++;
                }
            }
        }
        
        return allTags;
    }



    Future<String> getTagType(String tag) async {
        final Map<String, List> allSpecificTags = Map.from((await getRawInfo())["specificTags"]);
        return allSpecificTags.keys.firstWhere((type) => allSpecificTags[type]!.contains(tag), orElse: () => "generic");
    }
    Future<List<BooruTagCounterDisplay<NormalTag>>> getAllSavedTagsFromType(String type) async {
        final Map<String, List<String>> specificTags = Map<dynamic, List<dynamic>>.from(((await getRawInfo())["specificTags"]))
            .map((key, value) => MapEntry(key, value.cast<String>()),);
        final allTags = await getAllTags();

        if(type == "generic") {
            final anyTypedTag = specificTags.values.expand((e) => e).toList();
            return allTags.where((element) => !anyTypedTag.contains(element.tag.text)).toList();
        } else {
            return allTags.where((element) => specificTags[type]!.contains(element.tag.text)).toList();
        }
    }
    Future<Map<String, List<String>>> separateTagsByType(List<String> tags) async {
        List<String> genericList = List.from(tags);
        final Map<String, List> specificTags = Map.from((await getRawInfo())["specificTags"]);
        final Map<String, List<String>> result = {};
        for (final type in specificTags.keys) {
            result[type] = List.from(tags.toSet().intersection(specificTags[type]!.toSet()));
            genericList.removeWhere((element) => result[type]!.contains(element));
        }
        result["generic"] = genericList;
        return result;
    }



    BooruCollection _collectionFromRawMap(Map<String, dynamic> matchingCollection) {
        final String id = matchingCollection["id"].toString();
        final metadataToCheck = ["pages", "name", "id"];
        for (String metadata in metadataToCheck) {
            if(!matchingCollection.containsKey(metadata)) throw "Collection $id doesn't contain property $metadata";
        }

        final String collectionName = matchingCollection["name"] as String;
        final String folderName = (matchingCollection["folder"] as String?)?.trim().isNotEmpty == true
            ? matchingCollection["folder"] as String
            : sanitizeCollectionFolderName(collectionName);

        return BooruCollection(
            pages: List<ImageID>.from(matchingCollection["pages"]),
            name: collectionName,
            id: id,
            folder: folderName,
        );
    }

    Future<BooruCollection?> getCollection(CollectionID id) async {
        final List<Map<String, dynamic>> collections = List<Map<String, dynamic>>.from((await getRawInfo())["collections"]);

        final matchingCollection = collections.firstWhereOrNull((collection) => collection["id"] == id);
        if(matchingCollection == null) return null;

        return _collectionFromRawMap(matchingCollection);
    }
    Future<List<BooruCollection>> getAllCollections() async {
        final List<Map<String, dynamic>> collections = List<Map<String, dynamic>>.from((await getRawInfo())["collections"]);

        return collections.map(_collectionFromRawMap).toList();
    }
    Future<List<BooruCollection>> obtainMatchingCollection(ImageID imageID) async {
        final List<Map<String, dynamic>> collections = List<Map<String, dynamic>>.from((await getRawInfo())["collections"]);

        final foundCollections = collections.where((collection) => List<ImageID>.from(collection["pages"]).contains(imageID));

        return foundCollections.map(_collectionFromRawMap).toList();
    }

    Future<List<BooruImage>> getImagesFromCollectionOnIndex(BooruCollection collection, {int index = 0, int? size}) async {
        final List files = (await getRawInfo())["files"];
        final obtainedList = collection.pages
            .map((id) => files.firstWhereOrNull((f) => f["id"].toString() == id.toString()))
            .whereType<Map>()
            .toList();
        return await getImagesFromIndex(obtainedList, index: index, size: size);
    }
}

typedef ImageID = String;
class BooruImage {
    BooruImage({required this.id, required this.path, required this.tags, this.sources = const [], this.rating, this.note, this.relatedImages = const []}) {
        filename = p.basename(path);
    }

    ImageID id;
    String path;
    String filename = "";
    String tags;
    String? note;
    Rating? rating;
    List<String> sources;
    List<ImageID> relatedImages;

    File getImage() => File(path);
}

typedef CollectionID = String;
class BooruCollection {
    BooruCollection({required this.pages, required this.name, required this.id, this.folder});

    List<ImageID> pages;
    String name;
    CollectionID id;
    String? folder;
}

enum Rating {safe, questionable, explicit, illegal}

class BooruTagCounterDisplay<T extends WorksWithTags> {
    BooruTagCounterDisplay({required this.tag, required this.callQuantity});

    T tag;
    int callQuantity;
}