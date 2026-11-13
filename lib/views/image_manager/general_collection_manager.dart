import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/components/multi_image_display.dart';

class GeneralCollectionManagerScreen extends StatefulWidget {
    const GeneralCollectionManagerScreen({
        super.key,
        this.displayImages,
        this.onCorelatedChanged,
        this.corelated,
        this.moveFiles,
        this.onMoveFilesChanged,
        this.sourceFolderName,
        this.saveCollectionToggle,
        this.onSaveCollectionToggle,
        this.existingCollections = const [],
        this.selectedExistingCollectionId,
        this.onSelectedExistingCollectionChanged,
        required this.collection,
        this.onErrorChange,
        this.onMultiCompress,
        this.progressMultiCompress,
        this.onMultiAutoTag,
        this.progressMultiAutoTag,
        this.statusMultiAutoTag,
    });

    final List<ImageProvider?>? displayImages;
    final void Function(bool value)? onCorelatedChanged;
    final bool? corelated;
    final bool? moveFiles;
    final void Function(bool value)? onMoveFilesChanged;
    final String? sourceFolderName;
    final void Function(bool value)? onSaveCollectionToggle;
    final bool? saveCollectionToggle;
    final List<BooruCollection> existingCollections;
    final CollectionID? selectedExistingCollectionId;
    final void Function(CollectionID? id)? onSelectedExistingCollectionChanged;
    final void Function(bool value)? onErrorChange;
    final void Function()? onMultiCompress;
    final double? progressMultiCompress;
    final void Function()? onMultiAutoTag;
    final double? progressMultiAutoTag;
    final String? statusMultiAutoTag;
    final VirtualPresetCollection collection;

    @override
    State<GeneralCollectionManagerScreen> createState() => _GeneralCollectionManagerScreenState();
}

class _GeneralCollectionManagerScreenState extends State<GeneralCollectionManagerScreen> {
    late TextEditingController _nameController;

    @override
    void initState() {
        super.initState();
        _nameController = TextEditingController(text: widget.collection.name ?? "");
    }

    @override
    void didUpdateWidget(covariant GeneralCollectionManagerScreen oldWidget) {
        super.didUpdateWidget(oldWidget);
        if (widget.collection.name != _nameController.text && widget.collection.name != null) {
            _nameController.text = widget.collection.name!;
        }
    }

    @override
    void dispose() {
        _nameController.dispose();
        super.dispose();
    }

    @override
    Widget build(BuildContext context) {
        return ListView(
            children: [
                if(widget.displayImages != null) ...[
                    Center(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 225),
                            child: AspectRatio(
                                aspectRatio: 1,
                                child: MultipleImage(
                                    images: widget.displayImages!,
                                ),
                            ),
                        ),
                    ),
                    const SizedBox(height: 16,)
                ],

                if (widget.sourceFolderName != null && widget.saveCollectionToggle != null)
                    Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: SwitchListTile(
                            title: Text("Preservar pasta '${widget.sourceFolderName}' como Collection"),
                            subtitle: Text((widget.saveCollectionToggle ?? false)
                                ? "A pasta será ${(widget.moveFiles ?? false) ? 'movida' : 'copiada'} para booru/files/${(widget.collection.name?.isNotEmpty == true) ? widget.collection.name : widget.sourceFolderName} e se tornará uma Collection"
                                : "As imagens serão salvas soltas em booru/files sem preservar a pasta"),
                            secondary: const Icon(Icons.folder_special),
                            value: widget.saveCollectionToggle!,
                            onChanged: (value) {
                                if (value && (widget.collection.name == null || widget.collection.name!.isEmpty)) {
                                    widget.collection.name = widget.sourceFolderName;
                                    _nameController.text = widget.sourceFolderName!;
                                }
                                if (value && widget.onSelectedExistingCollectionChanged != null) {
                                    widget.onSelectedExistingCollectionChanged!(null);
                                }
                                widget.onSaveCollectionToggle?.call(value);
                                widget.onErrorChange?.call(value ? (widget.collection.name?.isEmpty ?? true) : false);
                                setState(() {});
                            },
                        ),
                    ),

                if(widget.moveFiles != null) SwitchListTile(
                    title: const Text("Move files instead of copying"),
                    subtitle: Text(widget.moveFiles!
                        ? "Mode: Move (files/folder will be moved into the booru and removed from the original location)"
                        : "Mode: Copy (files/folder will be copied into the booru, keeping originals intact)"),
                    secondary: Icon(widget.moveFiles! ? Icons.drive_file_move : Icons.copy_all),
                    value: widget.moveFiles!,
                    onChanged: widget.onMoveFilesChanged,
                ),
                if(widget.corelated != null) SwitchListTile(
                    title: const Text("Relate all images together"),
                    subtitle: const Text("Make each added image related to the others in the batch. Useful if you want to add alternative versions of an image"),
                    secondary: const Icon(Icons.hub_outlined),
                    value: widget.corelated!,
                    onChanged: widget.onCorelatedChanged
                ),
                if(widget.onMultiAutoTag != null) ListTile(
                    title: const Text("Auto-tag all images (WaifuTagger)"),
                    subtitle: widget.progressMultiAutoTag != null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                if (widget.statusMultiAutoTag != null) Text(widget.statusMultiAutoTag!),
                                const SizedBox(height: 4),
                                LinearProgressIndicator(value: widget.progressMultiAutoTag),
                            ],
                        )
                        : const Text("Automatically generate tags for all images in this batch"),
                    leading: const Icon(CupertinoIcons.sparkles),
                    onTap: widget.onMultiAutoTag,
                    enabled: widget.progressMultiAutoTag == null,
                ),
                if(widget.onMultiCompress != null) ListTile(
                    title: const Text("Compress all images"),
                    subtitle: widget.progressMultiCompress != null ? LinearProgressIndicator(value: widget.progressMultiCompress,) : const Text("Compress all images all at once"),
                    leading: const Icon(Icons.compress),
                    onTap: widget.onMultiCompress,
                    enabled: widget.progressMultiCompress == null,
                ),
                const Divider(),
                if(widget.saveCollectionToggle != null) ExpansionTile(
                    title: const Text("Collections & Folder Storage"),
                    subtitle: const Text("Create a new collection folder or add to an existing collection folder"),
                    leading: Icon(Icons.photo_library, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    initiallyExpanded: true,
                    shape: const RoundedRectangleBorder(side: BorderSide.none),
                    collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
                    children: [
                        if (widget.existingCollections.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                child: DropdownButtonFormField<CollectionID?>(
                                    value: (widget.saveCollectionToggle ?? false) ? null : widget.selectedExistingCollectionId,
                                    decoration: const InputDecoration(
                                        labelText: "Add to existing Collection (Folder)",
                                        prefixIcon: Icon(Icons.folder_open),
                                    ),
                                    items: [
                                        const DropdownMenuItem<CollectionID?>(
                                            value: null,
                                            child: Text("None / Create new below"),
                                        ),
                                        ...widget.existingCollections.map((col) => DropdownMenuItem<CollectionID?>(
                                            value: col.id,
                                            child: Text("${col.name} (files/${col.folder ?? col.name})"),
                                        )),
                                    ],
                                    onChanged: (colId) {
                                        if (colId != null) {
                                            widget.onSaveCollectionToggle?.call(false);
                                            widget.onErrorChange?.call(false);
                                        }
                                        widget.onSelectedExistingCollectionChanged?.call(colId);
                                    },
                                ),
                            ),
                        SwitchListTile(
                            title: const Text("Create a new collection (and folder in booru/files)"),
                            subtitle: const Text("Creates a new collection and a matching folder inside booru/files"),
                            value: widget.saveCollectionToggle!,
                            onChanged: (value) {
                                if (value && widget.onSelectedExistingCollectionChanged != null) {
                                    widget.onSelectedExistingCollectionChanged!(null);
                                }
                                if(widget.onSaveCollectionToggle != null) widget.onSaveCollectionToggle!(value);
                                widget.onErrorChange!(value ? widget.collection.name?.isEmpty ?? true : false);
                            }
                        ),
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: TextFormField(
                                controller: _nameController,
                                decoration: const InputDecoration(
                                    labelText: "Name of collection / folder"
                                ),
                                enabled: widget.saveCollectionToggle ?? true,
                                validator: (value) => value != null && value.isNotEmpty ? null : "Value is empty",
                                onChanged: (value) {
                                    widget.collection.name = value;
                                    if(widget.onErrorChange != null) widget.onErrorChange!(value.isEmpty);
                                },
                            ),
                        ),
                    ],
                )
            ],
        );
    }
}
