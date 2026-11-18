import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/tags/index.dart';
import 'package:localbooru/components/dialogs/image_selector_dialog.dart';
import 'package:localbooru/components/headers.dart';
import 'package:localbooru/components/dialogs/radio_dialogs.dart';
import 'package:localbooru/utils/constants.dart';
import 'package:localbooru/views/image_manager/components/image_upload.dart';
import 'package:localbooru/views/image_manager/components/list_string_text_input.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/views/image_manager/components/related_images.dart';
import 'package:localbooru/views/image_manager/components/tagfield.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ImageManagerForm extends StatefulWidget {
    const ImageManagerForm({
        super.key,
        this.preset,
        required this.onChanged,
        this.onMultipleImagesAdded,
        this.onAutoTagAll,
        this.onErrorUpdate,
        this.showRelatedImagesCard = true,
        this.updateNotifier,
        this.moveFiles,
        this.onMoveFilesChanged,
        this.existingCollections = const [],
        this.selectedExistingCollectionId,
        this.onSelectedExistingCollectionChanged,
        this.progressMultiAutoTag,
        this.statusMultiAutoTag,
    });

    final PresetImage? preset;
    final bool showRelatedImagesCard;
    // final bool shouldOpenRecents;
    final void Function(PresetImage preset) onChanged;
    final void Function(bool hasError)? onErrorUpdate;
    final void Function(List<File> files)? onMultipleImagesAdded;
    final Future<void> Function()? onAutoTagAll;
    final ChangeNotifier? updateNotifier;
    final bool? moveFiles;
    final void Function(bool value)? onMoveFilesChanged;
    final List<BooruCollection> existingCollections;
    final CollectionID? selectedExistingCollectionId;
    final void Function(CollectionID? id)? onSelectedExistingCollectionChanged;
    final double? progressMultiAutoTag;
    final String? statusMultiAutoTag;

    @override
    State<ImageManagerForm> createState() => _ImageManagerFormState();
}

class _ImageManagerFormState extends State<ImageManagerForm> {
    final _formKey = GlobalKey<FormState>();

    final tagController = TextEditingController();
    final artistTagController = TextEditingController();
    final characterTagController = TextEditingController();
    final copyrightTagController = TextEditingController();
    final speciesTagController = TextEditingController();

    final totallyNotTemporary = TextEditingController();

    bool isEditing = false;
    bool isGeneratingTags = false;
    bool isSaving = false;
    
    Rating? rating;

    List<String> urlList = [];
    String loadedImage = "";
    File? originalFile;

    List<ImageID> relatedImages = [];

    @override
    void initState() {
        super.initState();
        isEditing = widget.preset?.replaceID != null;
        
        if(widget.preset != null) updateInformation(widget.preset!);
        if(widget.updateNotifier != null) widget.updateNotifier!.addListener(updateListenable);
    }

    @override
    void didUpdateWidget(covariant ImageManagerForm oldWidget) {
        super.didUpdateWidget(oldWidget);
        if (widget.updateNotifier != oldWidget.updateNotifier) {
            oldWidget.updateNotifier?.removeListener(updateListenable);
            widget.updateNotifier?.addListener(updateListenable);
        }
        isEditing = widget.preset?.replaceID != null;
        if (widget.preset != null) {
            if (widget.preset != oldWidget.preset) {
                if ((widget.preset!.image?.path ?? "") != loadedImage ||
                    _controllerTagsDifferFromPreset(widget.preset!) ||
                    (_areAllTagControllersEmpty() && _hasAnyTags(widget.preset!.tags))) {
                    updateInformation(widget.preset!);
                }
            } else if (_areAllTagControllersEmpty() && _hasAnyTags(widget.preset!.tags)) {
                updateInformation(widget.preset!);
            }
        }
    }

    bool _areAllTagControllersEmpty() {
        return tagController.text.trim().isEmpty &&
            artistTagController.text.trim().isEmpty &&
            characterTagController.text.trim().isEmpty &&
            copyrightTagController.text.trim().isEmpty &&
            speciesTagController.text.trim().isEmpty;
    }

    bool _hasAnyTags(Map<String, List<String>>? tags) {
        if (tags == null) return false;
        return tags.values.any((list) => list.any((t) => t.trim().isNotEmpty));
    }

    bool _controllerTagsDifferFromPreset(PresetImage preset) {
        const eq = ListEquality<String>();
        final Map<String, TextEditingController> controllersByType = {
            "generic": tagController,
            "artist": artistTagController,
            "character": characterTagController,
            "copyright": copyrightTagController,
            "species": speciesTagController,
        };
        for (final entry in controllersByType.entries) {
            final currentTags = entry.value.text.split(" ").where((e) => e.isNotEmpty).toList();
            final presetTags = (preset.tags?[entry.key] ?? []).where((e) => e.isNotEmpty).toList();
            if (!eq.equals(currentTags, presetTags)) return true;
        }
        return false;
    }

    @override
    void dispose() {
        tagController.dispose();
        artistTagController.dispose();
        characterTagController.dispose();
        copyrightTagController.dispose();
        speciesTagController.dispose();
        if(widget.updateNotifier != null) {
            widget.updateNotifier!.removeListener(updateListenable);
        }

        super.dispose();
    }

    void updateListenable() {
        if (mounted && widget.preset != null) {
            setState(() {
                updateInformation(widget.preset!);
            });
        }
    }

    void updateInformation(PresetImage preset) {
        if(preset.image != null) loadedImage = preset.image!.path;
        originalFile = preset.originalImage ?? preset.image;
        if(preset.sources != null) urlList = preset.sources!;
        rating = preset.rating;
        if(preset.relatedImages != null) relatedImages = preset.relatedImages ?? [];

        if(preset.tags != null) {
            tagController.text = preset.tags!["generic"]?.join(" ") ?? "";
            artistTagController.text = preset.tags!["artist"]?.join(" ") ?? "";
            characterTagController.text = preset.tags!["character"]?.join(" ") ?? "";
            copyrightTagController.text = preset.tags!["copyright"]?.join(" ") ?? "";
            speciesTagController.text = preset.tags!["species"]?.join(" ") ?? "";
        } else {
            tagController.text = "";
            artistTagController.text = "";
            characterTagController.text = "";
            copyrightTagController.text = "";
            speciesTagController.text = "";
        }
    }

    void sendPreset() async {
        final validation = _formKey.currentState!.validate();
        widget.onChanged(PresetImage(
            image: File(loadedImage),
            originalImage: originalFile ?? widget.preset?.originalImage ?? (loadedImage.isNotEmpty ? File(loadedImage) : null),
            tags: {
                "generic": tagController.text.split(" ").where((e) => e.isNotEmpty).toList(),
                "artist": artistTagController.text.split(" ").where((e) => e.isNotEmpty).toList(),
                "character": characterTagController.text.split(" ").where((e) => e.isNotEmpty).toList(),
                "copyright": copyrightTagController.text.split(" ").where((e) => e.isNotEmpty).toList(),
                "species": speciesTagController.text.split(" ").where((e) => e.isNotEmpty).toList()
            },
            sources: urlList,
            rating: rating,
            replaceID: widget.preset?.replaceID,
            relatedImages: relatedImages,
            key: widget.preset?.key,
            note: widget.preset?.note
        ));
        if(widget.onErrorUpdate != null) widget.onErrorUpdate!(!validation);
    }

    void _addVideoTagIfMissing() {
        final currentTags = tagController.text
            .split(" ")
            .where((e) => e.isNotEmpty && e != "tagme")
            .toList();
        if (!currentTags.contains("video")) {
            currentTags.add("video");
            tagController.text = currentTags.join(" ");
        }
    }

    void fetchTags() async {
        if (isVideoFile(loadedImage)) {
            setState(() {
                _addVideoTagIfMissing();
            });
            sendPreset();
            return;
        }
        final prefs = await SharedPreferences.getInstance();
        setState(() => isGeneratingTags = true);
        final double threshold = prefs.getDouble("autotag_accuracy") ?? settingsDefaults["autotag_accuracy"];
        autoTagDetailed(File(loadedImage), threshold: threshold).then((detailed) async {
            final separatedTags = detailed.separatedTags;

            String mergeUnique(String existing, List<String>? added) {
                final set = <String>{
                    ...existing.split(" ").where((e) => e.isNotEmpty && e != "tagme"),
                    ...(added ?? []).where((e) => e.isNotEmpty),
                };
                return set.join(" ");
            }

            String mergedGeneric = mergeUnique(tagController.text, separatedTags["generic"]);
            final String mergedArtist = mergeUnique(artistTagController.text, separatedTags["artist"]);
            final String mergedCharacter = mergeUnique(characterTagController.text, separatedTags["character"]);
            final String mergedCopyright = mergeUnique(copyrightTagController.text, separatedTags["copyright"]);
            final String mergedSpecies = mergeUnique(speciesTagController.text, separatedTags["species"]);

            if (mergedGeneric.isEmpty &&
                mergedArtist.isEmpty &&
                mergedCharacter.isEmpty &&
                mergedCopyright.isEmpty &&
                mergedSpecies.isEmpty) {
                if (detailed.allTags.isNotEmpty) {
                    final sorted = detailed.allTags.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value));
                    mergedGeneric = sorted
                        .where((e) => e.value >= 0.10)
                        .take(15)
                        .map((e) => e.key)
                        .join(" ");
                }
                if (mergedGeneric.isEmpty) {
                    mergedGeneric = "tagme";
                }
            }

            setState(() {
                tagController.text = mergedGeneric;
                artistTagController.text = mergedArtist;
                characterTagController.text = mergedCharacter;
                copyrightTagController.text = mergedCopyright;
                speciesTagController.text = mergedSpecies;
                if (rating == null && detailed.rating != null) {
                    rating = detailed.rating;
                }
            });
            sendPreset();
        }).catchError((error, stackTrace) {
            if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Could not obtain tag information: ${error.toString()}'),
                ));
            }
        }).whenComplete(() {
            if (mounted) setState(() => isGeneratingTags = false);
        });
    }

    String? validateTagTexts(String? value, String type) {
        if(value == null || value.isNotEmpty) {
            final splitValue = value?.split(" ") ?? [];
            // check for overlaps
            List hasOverlap = [false, ""];

            if(type != "generic" && !hasOverlap[0]) hasOverlap = [tagController.text.split(" ").toSet().intersection(splitValue.toSet()).isNotEmpty, "generic"];
            if(type != "artist" && !hasOverlap[0]) hasOverlap = [artistTagController.text.split(" ").toSet().intersection(splitValue.toSet()).isNotEmpty, "artist"];
            if(type != "character" && !hasOverlap[0]) hasOverlap = [characterTagController.text.split(" ").toSet().intersection(splitValue.toSet()).isNotEmpty, "character"];
            if(type != "copyright" && !hasOverlap[0]) hasOverlap = [copyrightTagController.text.split(" ").toSet().intersection(splitValue.toSet()).isNotEmpty, "copyright"];
            if(type != "species" && !hasOverlap[0]) hasOverlap = [speciesTagController.text.split(" ").toSet().intersection(splitValue.toSet()).isNotEmpty, "species"];
            
            if(hasOverlap[0]) return "Overlapping tags exists with the ${hasOverlap[1]} field";
            
            //check for metatags
            for(final tag in splitValue) {
                if(Metatag.isMetatag(tag)) return "Metatags cannot be added";
            }
        }

        // check if it is empty
        if([tagController, artistTagController, characterTagController, copyrightTagController, speciesTagController]
            .every((controller) => controller.text.isEmpty)) return "Please insert a tag";

        return null;
    }

    @override
    Widget build(BuildContext context) {
        return OrientationBuilder(
            builder: (context, orientation) => Form(
                key: _formKey,
                child: ListView(
                    padding: const EdgeInsets.all(16.0),
                    children: [
                        ImageUploadForm(
                            onChanged: (value) {
                                final firstFile = value.first;
                                setState(() {
                                    loadedImage = firstFile.path;
                                    originalFile = firstFile;
                                    if (isVideoFile(firstFile.path)) {
                                        _addVideoTagIfMissing();
                                    }
                                });
                                sendPreset();
                                if(value.length > 1 && widget.onMultipleImagesAdded != null) widget.onMultipleImagesAdded!(value..removeAt(0));
                            },
                            onCompressed: (value) {
                                setState(() {
                                    originalFile ??= loadedImage.isNotEmpty ? File(loadedImage) : null;
                                    loadedImage = value;
                                });
                                sendPreset();
                            },
                            validator: (value) {
                                if (value == null || value.isEmpty) return 'Please select an image';
                                return null;
                            },
                            currentValue: loadedImage,
                            orientation: orientation,
                        ),
                        if (!isEditing && widget.moveFiles != null)
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text("Move file instead of copying"),
                                subtitle: Text(widget.moveFiles!
                                    ? "Move into booru/files (removes original file)"
                                    : "Copy into booru/files (keeps original file)"),
                                secondary: Icon(widget.moveFiles! ? Icons.drive_file_move : Icons.copy_all),
                                value: widget.moveFiles!,
                                onChanged: widget.onMoveFilesChanged,
                            ),
                        if (!isEditing && widget.existingCollections.isNotEmpty && widget.onSelectedExistingCollectionChanged != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: DropdownButtonFormField<CollectionID?>(
                                    value: widget.selectedExistingCollectionId,
                                    decoration: const InputDecoration(
                                        labelText: "Add to Collection (Folder)",
                                        prefixIcon: Icon(Icons.folder_open),
                                    ),
                                    items: [
                                        const DropdownMenuItem<CollectionID?>(
                                            value: null,
                                            child: Text("None (Root files/)"),
                                        ),
                                        ...widget.existingCollections.map((col) => DropdownMenuItem<CollectionID?>(
                                            value: col.id,
                                            child: Text("${col.name} (files/${col.folder ?? col.name})"),
                                        )),
                                    ],
                                    onChanged: widget.onSelectedExistingCollectionChanged,
                                ),
                            ),
                        const SizedBox(height: 16,),
                        Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                                const SmallHeader("Tags", padding: EdgeInsets.zero),
                                Wrap(
                                    spacing: 4,
                                    children: [
                                        TextButton(
                                            onPressed: (loadedImage.isEmpty || isGeneratingTags) ? null : fetchTags, 
                                            child: Wrap(
                                                spacing: 8,
                                                children: [
                                                    const Icon(CupertinoIcons.sparkles),
                                                    isGeneratingTags ? const Text("Generating...") : const Text("Generate tags")
                                                ],
                                            )
                                        ),
                                        if (widget.onAutoTagAll != null)
                                            TextButton(
                                                onPressed: (isGeneratingTags || widget.progressMultiAutoTag != null) ? null : () => widget.onAutoTagAll!(),
                                                child: const Wrap(
                                                    spacing: 6,
                                                    children: [
                                                        Icon(Icons.auto_awesome_motion),
                                                        Text("Auto-tag all"),
                                                    ],
                                                ),
                                            ),
                                    ],
                                )
                            ],
                        ),
                        if (widget.progressMultiAutoTag != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                        if (widget.statusMultiAutoTag != null)
                                            Text(
                                                widget.statusMultiAutoTag!,
                                                style: Theme.of(context).textTheme.bodySmall,
                                            ),
                                        const SizedBox(height: 4),
                                        LinearProgressIndicator(value: widget.progressMultiAutoTag),
                                    ],
                                ),
                            ),
                        ListenableBuilder(
                            listenable: Listenable.merge([
                                tagController,
                                artistTagController,
                                characterTagController,
                                copyrightTagController,
                                speciesTagController,
                            ]),
                            builder: (context, _) {
                                final categorizedControllers = <({String type, TextEditingController controller})>[
                                    (type: "artist", controller: artistTagController),
                                    (type: "character", controller: characterTagController),
                                    (type: "copyright", controller: copyrightTagController),
                                    (type: "species", controller: speciesTagController),
                                    (type: "generic", controller: tagController),
                                ];
                                final chips = <Widget>[];
                                for (final item in categorizedControllers) {
                                    final color = SpecificTagsColors.getColor(item.type);
                                    final tags = item.controller.text
                                        .split(" ")
                                        .where((e) => e.isNotEmpty)
                                        .toList();
                                    for (final tag in tags) {
                                        chips.add(
                                            InputChip(
                                                label: Text(
                                                    tag,
                                                    style: TextStyle(color: color, fontSize: 12),
                                                ),
                                                visualDensity: VisualDensity.compact,
                                                backgroundColor: color.withValues(alpha: 0.12),
                                                side: BorderSide(color: color.withValues(alpha: 0.4)),
                                                deleteIcon: Icon(Icons.close, size: 14, color: color),
                                                onDeleted: () {
                                                    final remaining = item.controller.text
                                                        .split(" ")
                                                        .where((e) => e.isNotEmpty && e != tag)
                                                        .toList();
                                                    item.controller.text = remaining.join(" ");
                                                    sendPreset();
                                                },
                                            ),
                                        );
                                    }
                                }
                                if (chips.isEmpty) return const SizedBox.shrink();
                                return Padding(
                                    padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                    child: Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: chips,
                                    ),
                                );
                            },
                        ),
                        TagField(
                            controller: tagController,
                            decoration: const InputDecoration(
                                labelText: "General",
                            ),
                            style: const TextStyle(color: SpecificTagsColors.generic),
                            validator: (value) => validateTagTexts(value, "generic"),
                            onChanged: (_) => sendPreset()
                        ),
                        TagField(
                            controller: artistTagController,
                            decoration: const InputDecoration(
                                labelText: "Artist(s)"
                            ),
                            type: "artist",
                            style: const TextStyle(color: SpecificTagsColors.artist),
                            validator: (value) => validateTagTexts(value, "artist"),
                            onChanged: (_) => sendPreset()
                        ),
                        TagField(
                            controller: characterTagController,
                            decoration: const InputDecoration(
                                labelText: "Character(s)"
                            ),
                            type: "character",
                            style: const TextStyle(color: SpecificTagsColors.character),
                            validator: (value) => validateTagTexts(value, "character"),
                            onChanged: (_) => sendPreset()
                        ),
                        TagField(
                            controller: copyrightTagController,
                            decoration: const InputDecoration(
                                labelText: "Copyright"
                            ),
                            type: "copyright",
                            style: const TextStyle(color: SpecificTagsColors.copyright),
                            validator: (value) => validateTagTexts(value, "copyright"),
                            onChanged: (_) => sendPreset()
                        ),
                        TagField(
                            controller: speciesTagController,
                            decoration: const InputDecoration(
                                labelText: "Species"
                            ),
                            type: "species",
                            style: const TextStyle(color: SpecificTagsColors.species),
                            validator: (value) => validateTagTexts(value, "species"),
                            onChanged: (_) => sendPreset()
                        ),
                        
                        const SmallHeader("Rating", padding: EdgeInsets.only(top: 16.0)),
                        ListTile(
                            leading: Icon(getRatingIcon(rating)),
                            title: Text(getRatingText(rating)),
                            onTap: () async {
                                final choosenRating = await showDialog(
                                    context: context,
                                    builder: (_) => RatingChooserDialog(selected: rating, hasNull: true,)
                                );
                                if(choosenRating == null) return;
                                else if(choosenRating == "None") setState(() => rating = null);
                                else setState(() => rating = choosenRating);
                                debugPrint("from Rating");
                                sendPreset();
                            },
                        ),
            
                        const SmallHeader("Sources", padding: EdgeInsets.only(top: 16.0),),
                        ListStringTextInput(
                            addButton: const Text("Add source"),
                            onChanged: (list) {
                                setState(() => urlList = list);
                                sendPreset();
                            },
                            canBeEmpty: true,
                            defaultValue: urlList,
                            formValidator: (value) {
                                if(value == null || value.isEmpty) return "Please either remove the URL or fill this field";
                                return null;
                            },
                        ),
                        if(widget.showRelatedImagesCard) ...[
                            const SmallHeader("Related images", padding: EdgeInsets.only(top: 16.0, bottom: 8)),
                            RelatedImagesCard(
                                showBlockWarning: !widget.showRelatedImagesCard,
                                relatedImages: relatedImages,
                                onRemove: (imageID) {
                                    setState(() => relatedImages.remove(imageID));
                                    debugPrint("from RelatedImagesCard");
                                    sendPreset();
                                },
                                onAddButtonPress: () async {
                                    final imageList = await openSelectionDialog(
                                        context: context,
                                        selectedImages: relatedImages,
                                        excludeImages: widget.preset?.replaceID != null ? [widget.preset!.replaceID!] : null
                                    );
                                    if(imageList == null) return;
                                    setState(() {
                                        relatedImages = imageList;
                                    });
                                    sendPreset();
                                },
                            )
                        ]
                    ],
                ),
            )
        );
    }
}