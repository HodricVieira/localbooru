import 'dart:io';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/api/tags/index.dart';
import 'package:localbooru/components/app_bar_linear_progress.dart';
import 'package:localbooru/components/dialogs/download_dialog.dart';
import 'package:localbooru/components/dialogs/image_selector_dialog.dart';
import 'package:localbooru/components/dialogs/textfield_dialogs.dart';
import 'package:localbooru/shortcut_handler.dart';
import 'package:localbooru/utils/compressor.dart';
import 'package:localbooru/utils/constants.dart';
import 'package:localbooru/utils/listeners.dart';
import 'package:localbooru/utils/platform_tools.dart';
import 'package:localbooru/views/image_manager/components/image_upload.dart';
import 'package:localbooru/views/image_manager/form.dart';
import 'package:localbooru/views/image_manager/general_collection_manager.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class ImageManagerShell extends StatefulWidget {
    const ImageManagerShell({super.key, this.sendable});

    final ManageImageSendable? sendable;

    @override
    State<ImageManagerShell> createState() => _ImageManagerShellState();
}

class _ImageManagerShellState extends State<ImageManagerShell> {
    final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
    
    late VirtualPresetCollection preset;
    List<bool> errorOnPages = [false];
    bool isSaving = false;
    bool saveCollection = false;
    int savedImages = 0;
    double? progressCompressedImages;
    double? progressAutoTagImages;
    String? statusAutoTagImages;
    int imagePage = 0;

    bool isCorelated = false;
    bool moveFiles = false;
    String? sourceFolderPath;
    String? sourceFolderName;
    List<BooruCollection> existingCollections = [];
    CollectionID? selectedExistingCollectionId;


    AcessibleNotifyListenerNotifier updatePreset = AcessibleNotifyListenerNotifier();

    Future<void> _loadImportModePref() async {
        final prefs = await SharedPreferences.getInstance();
        final mode = prefs.getString("file_import_mode") ?? settingsDefaults["file_import_mode"];
        if (mounted) {
            setState(() => moveFiles = (mode == "move"));
        }
    }

    Future<void> _loadExistingCollections() async {
        try {
            final booru = await getCurrentBooru();
            final cols = await booru.getAllCollections();
            if (mounted) {
                setState(() => existingCollections = cols);
            }
        } catch (_) {}
    }

    Future<void> _setMoveFiles(bool value) async {
        setState(() => moveFiles = value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString("file_import_mode", value ? "move" : "copy");
    }

    @override
    void initState() {
        super.initState();
        _loadImportModePref();
        _loadExistingCollections();
        if(widget.sendable == null) preset = VirtualPresetCollection(pages: [PresetImage()]);
        if(widget.sendable is PresetManageImageSendable) {
            final singleSendable = widget.sendable as PresetManageImageSendable;
            preset = VirtualPresetCollection(pages: [singleSendable.preset]);
            selectedExistingCollectionId = singleSendable.targetCollectionId;
        }
        if(widget.sendable is PresetListManageImageSendable) {
            final listSendable = widget.sendable as PresetListManageImageSendable;
            preset = VirtualPresetCollection(
                pages: listSendable.presets,
                name: listSendable.sourceFolderName,
            );
            sourceFolderPath = listSendable.sourceFolderPath;
            sourceFolderName = listSendable.sourceFolderName;
            selectedExistingCollectionId = listSendable.targetCollectionId;
            if (listSendable.sourceFolderName != null && listSendable.targetCollectionId == null) {
                saveCollection = true;
            }
            if (listSendable.autoTagOnStart) {
                imagePage = -1;
            }
        }
        if(widget.sendable is VirtualPresetManageImageSendable) {
            saveCollection = true;
            preset = (widget.sendable as VirtualPresetManageImageSendable).preset;
        }

        if(preset.pages == null || preset.pages!.isEmpty) preset.pages = [PresetImage()];
        errorOnPages.addAll(List.generate(preset.pages!.length, (index) => preset.pages![index].image == null || preset.pages![index].tags == null));

        if (widget.sendable is PresetListManageImageSendable && (widget.sendable as PresetListManageImageSendable).autoTagOnStart) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
                autoTagAllImages();
            });
        }
    }

    void saveImages() async {
        setState(() => isSaving = true);
        
        try {
            final booru = await getCurrentBooru();
            final listLength = await booru.getListLength();

            final List<ImageID> imaginaryIDs = preset.pages!.mapIndexed((index, preset) {
                if(preset.replaceID != null) return preset.replaceID!;
                return "${index + listLength}";
            }).toList();

            String? targetSubfolder;
            if (saveCollection) {
                final colName = (preset.name?.trim().isNotEmpty == true)
                    ? preset.name!.trim()
                    : (sourceFolderName ?? "Collection");
                preset.name = colName;
                targetSubfolder = sanitizeCollectionFolderName(colName);
            } else if (selectedExistingCollectionId != null) {
                final existingCol = existingCollections.firstWhereOrNull((c) => c.id == selectedExistingCollectionId)
                    ?? await booru.getCollection(selectedExistingCollectionId!);
                if (existingCol != null) {
                    targetSubfolder = existingCol.folder ?? sanitizeCollectionFolderName(existingCol.name);
                }
            }
            
            for (final (index, imagePreset) in preset.pages!.indexed) {
                if(isCorelated && preset.pages!.length > 1) {
                    final selfID = imaginaryIDs[index];
                    imagePreset.relatedImages = imaginaryIDs.where((id) => id != selfID).toList();
                }
                imagePreset.replaceID ??= imaginaryIDs[index];
                imagePreset.tags ??= {"generic": ["tagme"]};

                await insertImage(
                    imagePreset,
                    notify: false,
                    moveFile: moveFiles,
                    targetSubfolder: targetSubfolder,
                );
                if (mounted) setState(() => savedImages++);
            }

            if(saveCollection) {
                preset.pages = imaginaryIDs.mapIndexed((idx, id) => PresetImage(replaceID: id, image: preset.pages![idx].image, tags: preset.pages![idx].tags)).toList();
                await insertCollection(PresetCollection.fromVirtualPresetCollection(preset), notify: false);
            } else if (selectedExistingCollectionId != null) {
                await addImagesToCollection(selectedExistingCollectionId!, imaginaryIDs, notify: false);
            }

            if (moveFiles && sourceFolderPath != null) {
                try {
                    final sourceDir = Directory(sourceFolderPath!);
                    if (!p.isWithin(booru.path, sourceDir.path) &&
                        !p.equals(booru.path, sourceDir.path) &&
                        await sourceDir.exists() &&
                        await sourceDir.list().isEmpty) {
                        await sourceDir.delete();
                    }
                } catch (e) {
                    debugPrint("Could not remove empty source folder ($sourceFolderPath): $e");
                }
            }
            booruUpdateListener.update();
            counterListener.update();
            
            if(context.mounted) context.pop();
        } catch (e) {
            if (mounted) {
                setState(() => isSaving = false);
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Erro ao salvar imagens: $e")),
                );
            }
        }
    }

    String generateName(PresetImage imagePreset) {
        return imagePreset.image != null ? p.basenameWithoutExtension(imagePreset.image!.path) : "Image ${preset.pages!.indexOf(imagePreset) + 1}";
    }

    bool hasError() => errorOnPages.any((element) => element,);

    void addMultipleImages(List<File> files) {
        if (files.isEmpty) return;
        for (final file in files) {
            preset.pages!.add(PresetImage(image: file, key: UniqueKey()));
            errorOnPages.add(true);
        }
        setState(() {});
    }

    void compressAllImages() async {
        setState(() {progressCompressedImages = 0;});
        final presetsToCompressLength = preset.pages!.where((image) => image.image != null,).length;
        for (final (index, presetImage) in preset.pages!.indexed) {
            if(presetImage.image == null) continue;
            final file = await compress(presetImage.image!);
            preset.pages![index].image = file;
            setState(() {progressCompressedImages = index / presetsToCompressLength;});
        }
        updatePreset.update();
        setState(() {progressCompressedImages = null;});
    }

    Future<void> autoTagAllImages() async {
        if (progressAutoTagImages != null) return;
        final prefs = await SharedPreferences.getInstance();
        final double threshold = prefs.getDouble("autotag_accuracy") ?? settingsDefaults["autotag_accuracy"];
        final total = preset.pages!.where((image) => image.image != null).length;
        if (total == 0) return;

        setState(() {
            progressAutoTagImages = 0.0;
            statusAutoTagImages = "0 / $total";
        });

        int processed = 0;
        int failed = 0;
        String? lastError;

        for (final (index, presetImage) in preset.pages!.indexed) {
            if (presetImage.image == null) continue;
            if (!mounted) return;
            setState(() {
                statusAutoTagImages = "Tagging ${processed + 1} / $total (${p.basename(presetImage.image!.path)})...";
            });
            try {
                final detailed = await autoTagDetailed(presetImage.image!, threshold: threshold);
                final existingTags = presetImage.tags ?? {};
                Map<String, List<String>> mergedTags = {};
                for (final type in ["generic", "artist", "character", "copyright", "species"]) {
                    final set = <String>{
                        ...(existingTags[type] ?? []).where((e) => e.isNotEmpty && e != "tagme"),
                        ...(detailed.separatedTags[type] ?? []).where((e) => e.isNotEmpty),
                    };
                    mergedTags[type] = set.toList();
                }
                if (mergedTags.values.every((list) => list.isEmpty) && detailed.allTags.isNotEmpty) {
                    final sorted = detailed.allTags.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value));
                    mergedTags["generic"] = sorted
                        .where((e) => e.value >= 0.10)
                        .take(15)
                        .map((e) => e.key)
                        .toList();
                }
                if (mergedTags.values.every((list) => list.isEmpty)) {
                    mergedTags["generic"] = ["tagme"];
                }
                preset.pages![index].tags = mergedTags;
                preset.pages![index].rating ??= detailed.rating;
                if (index + 1 < errorOnPages.length) {
                    errorOnPages[index + 1] = false;
                }
            } catch (e) {
                failed++;
                lastError = e.toString();
                debugPrint("AutoTag failed on ${presetImage.image!.path}: $e");
                preset.pages![index].tags ??= {"generic": ["tagme"]};
                if (index + 1 < errorOnPages.length) {
                    errorOnPages[index + 1] = false;
                }
            }
            processed++;
            if (mounted) {
                setState(() {
                    progressAutoTagImages = processed / total;
                });
            }
        }
        updatePreset.update();
        if (mounted) {
            setState(() {
                progressAutoTagImages = null;
                statusAutoTagImages = null;
            });
            final message = failed == 0
                ? "Auto-tagging concluído para $processed imagens!"
                : "Auto-tagging: ${processed - failed}/$processed concluídas ($failed falharam: $lastError)";
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(message),
                    duration: Duration(seconds: failed == 0 ? 4 : 8),
                ),
            );
        }
    }

    @override
    Widget build(BuildContext context) {
        return ShortcutHandler(
            paste: (context) => CallbackPasteImageAction((intent, clipboardImages) {
                final isFirstEmptyAndIsSelectingFirst = preset.pages!.first.image == null && imagePage == 0;
                List<File> images = clipboardImages;
                if(isFirstEmptyAndIsSelectingFirst) {
                    final firstFile = images.removeAt(0);
                    preset.pages!.first.image = firstFile;
                    updatePreset.update();
                }
                addMultipleImages(images);
                setState(() => imagePage = preset.pages!.length - 1);
                _scaffoldKey.currentState!.closeEndDrawer();
            },),
            child: OrientationBuilder(
                builder: (context, orientation) => Scaffold(
                    key: _scaffoldKey,
                    appBar: AppBar(
                        title: imagePage >= 0 ? ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text("${preset.pages![imagePage].replaceID != null ? "Edit" : "Add"} image", style: const TextStyle(fontSize: 20.0), overflow: TextOverflow.ellipsis),
                            subtitle: Text(generateName(preset.pages![imagePage]), style: const TextStyle(fontSize: 14.0), overflow: TextOverflow.ellipsis),
                        ) : Text("${preset.pages!.length} images"),
                        actions: [
                            IconButton(
                                icon: Badge(
                                    padding: EdgeInsets.zero,
                                    label: Wrap(
                                        children: [
                                            if(saveCollection) Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                                decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: Theme.of(context).colorScheme.onTertiaryContainer
                                                ),
                                                child: const Text("C"),
                                            ),
                                            if(preset.pages!.length > 1) Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                                child: Text("${preset.pages!.length}"),
                                            )
                                        ],
                                    ),
                                    offset: Offset(preset.pages!.length > 1 && saveCollection ? 0 : 7, -7),
                                    isLabelVisible: preset.pages!.length > 1 || saveCollection,
                                    child: const Icon(Icons.library_add),
                                ),
                                // icon: Icon(Icons.library_add),
                                tooltip: preset.pages!.length > 1 || saveCollection
                                    // ignore: prefer_interpolation_to_compose_strings
                                    ? "${preset.pages!.length} images will be added" + (saveCollection ? " and put inside a new collection": "")
                                    : "Add images in bulk",
                                onPressed: () => _scaffoldKey.currentState!.openEndDrawer(),
                            ),
                            // Tooltip(
                            //     message: hasError() ? "There's some errors to resolve" : null,
                            //     child: ,
                            // ),
                            orientation == Orientation.portrait ? IconButton(
                                icon: const Icon(Icons.check),
                                onPressed: !isSaving && progressAutoTagImages == null && !hasError() ? saveImages : null,
                                tooltip: !hasError() ? "Done" : null,
                            ) : TextButton.icon(
                                icon: const Icon(Icons.check),
                                label: const Text("Done"),
                                onPressed: !isSaving && progressAutoTagImages == null && !hasError() ? saveImages : null,
                            )
                        ],
                        bottom: isSaving ? AppBarLinearProgressIndicator(value: savedImages != 0 ? savedImages / preset.pages!.length : null,) : null,
                    ),
                    endDrawer: Drawer(
                        child: SingleChildScrollView(
                            child: SafeArea(
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                        Padding(
                                            padding: const EdgeInsets.all(16).copyWith(top: isMobile() ? 4 : 16),
                                            child: const Text("Bulk Adding"),
                                        ),
                                        ListTile(
                                            title: const Text("Manage images"),
                                            textColor: imagePage == -1 ? Theme.of(context).colorScheme.primary : null,
                                            iconColor: imagePage == -1 ? Theme.of(context).colorScheme.primary : null,
                                            leading: const Icon(Icons.photo_library),
                                            onTap: imagePage == -1 ? null : () {
                                                setState(() => imagePage = -1);
                                                _scaffoldKey.currentState!.closeEndDrawer();
                                            },
                                        ),
                                        SwitchListTile(
                                            title: const Text("Move files"),
                                            subtitle: Text(moveFiles ? "Move to booru/files" : "Copy to booru/files"),
                                            secondary: Icon(moveFiles ? Icons.drive_file_move : Icons.copy_all),
                                            value: moveFiles,
                                            onChanged: _setMoveFiles,
                                        ),
                                        const Divider(),
                                        ...List.generate(preset.pages!.length, (index) => ListTile(
                                            title: Text(generateName(preset.pages![index])),
                                            leading: const Icon(Icons.image_outlined),
                                            textColor: imagePage == index ? Theme.of(context).colorScheme.primary : null,
                                            iconColor: imagePage == index ? Theme.of(context).colorScheme.primary : null,
                                            onTap: imagePage == index ? null : () {
                                                setState(() => imagePage = index);
                                                _scaffoldKey.currentState!.closeEndDrawer();
                                            },
                                            trailing: preset.pages!.length == 1 ? null : IconButton(
                                                tooltip: "Remove",
                                                icon: const Icon(Icons.close),
                                                onPressed: () {
                                                    preset.pages!.removeAt(index);
                                                    if (index + 1 < errorOnPages.length) {
                                                        errorOnPages.removeAt(index + 1);
                                                    }
                                                    setState(() => imagePage = imagePage >= index ? imagePage - 1 : imagePage);
                                                },
                                            ),
                                        )),
                                        const Divider(),
                                        ListTile(
                                            title: const Text("Add image"),
                                            leading: const Icon(Icons.add),
                                            onTap: () async {
                                                final files = await selectFileModal(context: context);
                                                if (files != null) {
                                                    if(preset.pages!.first.image == null && preset.pages!.length == 1) {
                                                        preset.pages!.first.image = files.removeAt(0);
                                                        updatePreset.update();
                                                    }
                                                    addMultipleImages(files);
                                                    setState(() => imagePage = preset.pages!.length - 1);
                                                    _scaffoldKey.currentState!.closeEndDrawer();
                                                }
                                            }
                                        ),
                                        ListTile(
                                            title: const Text("Import folder & auto-tag"),
                                            leading: const Icon(Icons.create_new_folder_outlined),
                                            onTap: () async {
                                                _scaffoldKey.currentState!.closeEndDrawer();
                                                final folderSendable = await pickFolderAndPrepareSendable(context);
                                                if (folderSendable != null && mounted) {
                                                    sourceFolderPath = folderSendable.sourceFolderPath;
                                                    sourceFolderName = folderSendable.sourceFolderName;
                                                    if (folderSendable.sourceFolderName != null && selectedExistingCollectionId == null) {
                                                        preset.name = folderSendable.sourceFolderName;
                                                        saveCollection = true;
                                                    }
                                                    if (preset.pages!.length == 1 && preset.pages!.first.image == null) {
                                                        preset.pages = folderSendable.presets;
                                                        errorOnPages = [false, ...List.generate(folderSendable.presets.length, (_) => true)];
                                                    } else {
                                                        preset.pages!.addAll(folderSendable.presets);
                                                        errorOnPages.addAll(List.generate(folderSendable.presets.length, (_) => true));
                                                    }
                                                    setState(() => imagePage = -1);
                                                    await autoTagAllImages();
                                                }
                                            }
                                        ),
                                        ListTile(
                                            title: const Text("Auto-tag all images"),
                                            leading: const Icon(CupertinoIcons.sparkles),
                                            onTap: () async {
                                                _scaffoldKey.currentState!.closeEndDrawer();
                                                setState(() => imagePage = -1);
                                                await autoTagAllImages();
                                            }
                                        ),
                                        ListTile(
                                            title: const Text("Edit existing image"),
                                            leading: const Icon(Icons.edit),
                                            onTap: () async {
                                                final images = await openSelectionDialog(
                                                    context: context,
                                                    excludeImages: preset.pages!.where((imagePreset) => imagePreset.replaceID != null,).map((imagePreset) => imagePreset.replaceID!).toList()
                                                );
                                                if(images == null) return;
                                                final booru = await getCurrentBooru();
                                                preset.pages!.addAll(await Future.wait(images.map((id) async {
                                                    PresetImage image = await PresetImage.fromExistingImage((await booru.getImage(id))!);
                                                    errorOnPages.add(false);
                                                    return image;
                                                })));
                                                setState(() => imagePage = preset.pages!.length - 1);
                                                _scaffoldKey.currentState!.closeEndDrawer();
                                            }
                                        ),
                                                ListTile(
                                            title: const Text("Import from external website"),
                                            leading: const Icon(Icons.download),
                                            onTap: () async {
                                                final url = await showDialog<String>(
                                                    context: context,
                                                    builder: (context) {
                                                        return const InsertURLDialog();
                                                    },
                                                );
                                                if(url == null) return;
                                                final downloadedPreset = await importImageFromURL(url);
                                                if(downloadedPreset is PresetImage) {
                                                    preset.pages!.add(downloadedPreset);
                                                    errorOnPages.add(false);
                                                } else if (downloadedPreset is VirtualPresetCollection) {
                                                    final presets = downloadedPreset.pages;
                                                    if(presets == null) return;
                                                    preset.pages!.addAll(presets);
                                                    errorOnPages.addAll(List.generate(presets.length, (_) => false));
                                                }
                                                setState(() => imagePage = preset.pages!.length - 1);
                                                _scaffoldKey.currentState!.closeEndDrawer();
                                            }
                                        ),
                                    ],
                                ),
                            ),
                        ),
                    ),
                    body: PopScope(
                        canPop: false,
                        onPopInvokedWithResult: (didPop, _) {
                            if(didPop) return;
                            if(imagePage == 0) {
                                context.pop();
                            } else {
                                setState(() => imagePage = 0);
                            }
                        },
                        child: imagePage == -1
                            ? GeneralCollectionManagerScreen(
                                displayImages: List<ImageProvider?>.generate(
                                    3,
                                    (index) => preset.pages!.asMap().containsKey(index) && preset.pages![index].image != null
                                        ? ResizeImage(FileImage(preset.pages![index].image!), width: 400)
                                        : null,
                                ),
                                corelated: isCorelated,
                                onCorelatedChanged: (value) => setState(() => isCorelated = value),
                                moveFiles: moveFiles,
                                onMoveFilesChanged: _setMoveFiles,
                                sourceFolderName: sourceFolderName,
                                saveCollectionToggle: saveCollection,
                                onSaveCollectionToggle: (value) => setState(() => saveCollection = value),
                                existingCollections: existingCollections,
                                selectedExistingCollectionId: selectedExistingCollectionId,
                                onSelectedExistingCollectionChanged: (colId) => setState(() => selectedExistingCollectionId = colId),
                                collection: preset,
                                onErrorChange: (value) => setState(() => errorOnPages[0] = value),
                                onMultiCompress: compressAllImages,
                                progressMultiCompress: progressCompressedImages,
                                onMultiAutoTag: autoTagAllImages,
                                progressMultiAutoTag: progressAutoTagImages,
                                statusMultiAutoTag: statusAutoTagImages,
                            )
                            : ImageManagerForm(
                                key: ValueKey("form_${preset.pages![imagePage].key ?? imagePage}"),
                                preset: preset.pages![imagePage],
                                updateNotifier: updatePreset,
                                onChanged: (imagePreset) => setState(() => preset.pages![imagePage] = imagePreset),
                                onErrorUpdate: (containsError) => setState(() => errorOnPages[imagePage + 1] = containsError),
                                onMultipleImagesAdded: addMultipleImages,
                                moveFiles: moveFiles,
                                onMoveFilesChanged: _setMoveFiles,
                                existingCollections: existingCollections,
                                selectedExistingCollectionId: selectedExistingCollectionId,
                                onSelectedExistingCollectionChanged: (colId) => setState(() {
                                    selectedExistingCollectionId = colId;
                                    if (colId != null) {
                                        saveCollection = false;
                                        errorOnPages[0] = false;
                                    }
                                }),
                                onAutoTagAll: preset.pages!.length > 1
                                    ? () async {
                                        setState(() => imagePage = -1);
                                        await autoTagAllImages();
                                    }
                                    : null,
                                showRelatedImagesCard: !isCorelated,
                            ),
                    ),
                    // floatingActionButton: FloatingActionButton(onPressed: () => debugPrint("$errorOnPages"),),
                )
            ),
        );
    }
}

abstract class ManageImageSendable {}
class PresetManageImageSendable extends ManageImageSendable {
    PresetManageImageSendable(this.preset, {this.targetCollectionId});
    PresetImage preset;
    CollectionID? targetCollectionId;
}
class PresetListManageImageSendable extends ManageImageSendable {
    PresetListManageImageSendable(
        this.presets, {
        this.autoTagOnStart = false,
        this.sourceFolderPath,
        this.sourceFolderName,
        this.targetCollectionId,
    });
    List<PresetImage> presets;
    bool autoTagOnStart;
    String? sourceFolderPath;
    String? sourceFolderName;
    CollectionID? targetCollectionId;
}
class VirtualPresetManageImageSendable extends ManageImageSendable {
    VirtualPresetManageImageSendable(this.preset);
    VirtualPresetCollection preset;
}

ManageImageSendable handleSendable(VirtualPreset preset) {
    if(preset is VirtualPresetCollection) return VirtualPresetManageImageSendable(preset);
    else return PresetManageImageSendable(preset as PresetImage);
}

Future<PresetListManageImageSendable?> pickFolderAndPrepareSendable(
    BuildContext context, {
    bool autoTagOnStart = true,
    CollectionID? targetCollectionId,
}) async {
    try {
        final String? folderPath = await FilePicker.platform.getDirectoryPath();
        if (folderPath == null) return null;

        final dir = Directory(folderPath);
        if (!await dir.exists()) return null;

        final List<File> imageFiles = [];
        const supportedExts = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"};
        await for (final entity in dir.list(recursive: false, followLinks: false)) {
            if (entity is File) {
                final ext = p.extension(entity.path).toLowerCase();
                final mime = lookupMimeType(entity.path);
                if (supportedExts.contains(ext) || (mime != null && mime.startsWith("image/"))) {
                    imageFiles.add(entity);
                }
            }
        }

        imageFiles.sort((a, b) => a.path.compareTo(b.path));

        if (imageFiles.isEmpty) {
            if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Nenhuma imagem encontrada na pasta selecionada.")),
                );
            }
            return null;
        }

        final presets = imageFiles.map((f) => PresetImage(image: f, key: UniqueKey())).toList();
        return PresetListManageImageSendable(
            presets,
            autoTagOnStart: autoTagOnStart,
            sourceFolderPath: folderPath,
            sourceFolderName: p.basename(folderPath),
            targetCollectionId: targetCollectionId,
        );
    } catch (e) {
        if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Erro ao ler pasta: $e")),
            );
        }
        return null;
    }
}