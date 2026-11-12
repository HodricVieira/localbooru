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


    AcessibleNotifyListenerNotifier updatePreset = AcessibleNotifyListenerNotifier();

    @override
    void initState() {
        super.initState();
        if(widget.sendable == null) preset = VirtualPresetCollection(pages: [PresetImage()]);
        if(widget.sendable is PresetManageImageSendable) preset = VirtualPresetCollection(pages: [(widget.sendable as PresetManageImageSendable).preset]);
        if(widget.sendable is PresetListManageImageSendable) {
            final listSendable = widget.sendable as PresetListManageImageSendable;
            preset = VirtualPresetCollection(pages: listSendable.presets);
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
            
            for (final (index, imagePreset) in preset.pages!.indexed) {
                if(isCorelated && preset.pages!.length > 1) {
                    final selfID = imaginaryIDs[index];
                    imagePreset.relatedImages = imaginaryIDs.where((id) => id != selfID).toList();
                }
                imagePreset.replaceID ??= imaginaryIDs[index];
                imagePreset.tags ??= {"generic": ["tagme"]};

                await insertImage(imagePreset, notify: false);
                if (mounted) setState(() => savedImages++);
            }

            if(saveCollection) {
                preset.pages = imaginaryIDs.mapIndexed((idx, id) => PresetImage(replaceID: id, image: preset.pages![idx].image, tags: preset.pages![idx].tags)).toList();
                await insertCollection(PresetCollection.fromVirtualPresetCollection(preset));
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
        for (final file in files) {
            preset.pages!.add(PresetImage(image: file, key: UniqueKey()));
            errorOnPages.add(true);
        }
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
        final prefs = await SharedPreferences.getInstance();
        final double threshold = prefs.getDouble("autotag_accuracy") ?? settingsDefaults["autotag_accuracy"];
        final total = preset.pages!.where((image) => image.image != null).length;
        if (total == 0) return;

        setState(() {
            progressAutoTagImages = 0.0;
            statusAutoTagImages = "0 / $total";
        });

        int processed = 0;
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
                        ...(existingTags[type] ?? []).where((e) => e.isNotEmpty),
                        ...(detailed.separatedTags[type] ?? []).where((e) => e.isNotEmpty),
                    };
                    mergedTags[type] = set.toList();
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
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Auto-tagging concluído para $processed imagens!")),
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
                                onPressed: !isSaving && !hasError() ? saveImages : null,
                                tooltip: !hasError() ? "Done" : null,
                            ) : TextButton.icon(
                                icon: const Icon(Icons.check),
                                label: const Text("Done"),
                                onPressed: !isSaving && !hasError() ? saveImages : null,
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
                                                    errorOnPages.removeAt(index);
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
                                                // final images = await openSelectionDialog(
                                                //     context: context,
                                                //     excludeImages: preset.pages!.where((imagePreset) => imagePreset.replaceID != null,).map((imagePreset) => imagePreset.replaceID!).toList()
                                                // );
                                                if(downloadedPreset is PresetImage) {
                                                    preset.pages!.add(downloadedPreset);
                                                    errorOnPages.add(false);
                                                } else if (downloadedPreset is VirtualPresetCollection) {
                                                    final presets = downloadedPreset.pages;
                                                    if(presets == null) return;
                                                    preset.pages!.addAll(presets);
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
                                saveCollectionToggle: saveCollection,
                                onSaveCollectionToggle: (value) => setState(() => saveCollection = value),
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
    PresetManageImageSendable(this.preset);
    PresetImage preset;
}
class PresetListManageImageSendable extends ManageImageSendable {
    PresetListManageImageSendable(this.presets, {this.autoTagOnStart = false});
    List<PresetImage> presets;
    bool autoTagOnStart;
}
class VirtualPresetManageImageSendable extends ManageImageSendable {
    VirtualPresetManageImageSendable(this.preset);
    VirtualPresetCollection preset;
}

ManageImageSendable handleSendable(VirtualPreset preset) {
    if(preset is VirtualPresetCollection) return VirtualPresetManageImageSendable(preset);
    else return PresetManageImageSendable(preset as PresetImage);
}

Future<PresetListManageImageSendable?> pickFolderAndPrepareSendable(BuildContext context, {bool autoTagOnStart = true}) async {
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
        return PresetListManageImageSendable(presets, autoTagOnStart: autoTagOnStart);
    } catch (e) {
        if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Erro ao ler pasta: $e")),
            );
        }
        return null;
    }
}