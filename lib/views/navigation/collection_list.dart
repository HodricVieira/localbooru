import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/components/builders.dart';
import 'package:localbooru/components/context_menu.dart';
import 'package:localbooru/components/dialogs/confirm_dialogs.dart';
import 'package:localbooru/components/dialogs/textfield_dialogs.dart';
import 'package:localbooru/utils/listeners.dart';
import 'package:localbooru/views/image_manager/shell.dart';

class CollectionsListPage extends StatefulWidget {
    const CollectionsListPage({super.key, required this.booru});

    final Booru booru;

    @override
    State<CollectionsListPage> createState() => _CollectionsListPageState();
}

class _CollectionsListPageState extends State<CollectionsListPage> {
    late Future<List<BooruCollection>> collectionFuture;

    late LongPressDownDetails longTap;

    @override
    void initState() {
        super.initState();
        _refreshCollections();
        booruUpdateListener.addListener(_refreshCollections);
    }

    @override
    void dispose() {
        booruUpdateListener.removeListener(_refreshCollections);
        super.dispose();
    }

    void _refreshCollections() {
        if (mounted) {
            setState(() {
                collectionFuture = widget.booru.getAllCollections();
            });
        }
    }

    Future<void> _handleDeleteCollection(BooruCollection collection) async {
        if (!mounted) return;
        final deleted = await confirmAndDeleteCollection(context, collection);
        if (deleted && mounted) {
            _refreshCollections();
        }
    }

    void openContextMenu(Offset offset, BooruCollection collection) {
        final RenderObject? overlay = Overlay.of(context).context.findRenderObject();
        showMenu(
            context: context,
            position: RelativeRect.fromRect(
                Rect.fromLTWH(offset.dx, offset.dy, 10, 10),
                Rect.fromLTWH(0, 0, overlay!.paintBounds.size.width, overlay.paintBounds.size.height),
            ),
            items: [
                PopupMenuItem(
                    child: const Text("Edit collection"),
                    onTap: () => context.push("/settings/booru/collections?id=${collection.id}")
                ),
                PopupMenuItem(
                    child: Text("Delete collection", style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onTap: () => _handleDeleteCollection(collection),
                ),
            ]
        );
    }

    @override
    Widget build(BuildContext context) {
        return Scaffold(
            appBar: AppBar(
                title: const Text("Collections"),
                actions: [
                    IconButton(
                        icon: const Icon(Icons.create_new_folder_outlined),
                        tooltip: "Import folder as collection",
                        onPressed: () async {
                            final sendable = await pickFolderAndPrepareSendable(context, autoTagOnStart: true);
                            if (sendable != null && context.mounted) {
                                context.push("/manage_image", extra: sendable);
                            }
                        },
                    ),
                    IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: "Create collection & folder",
                        onPressed: () async {
                            final name = await showDialog<String>(
                                context: context,
                                builder: (context) => const AddCollectionDialog()
                            );
                            if(name == null || name.trim().isEmpty) return;
                            await insertCollection(PresetCollection(
                                name: name.trim(),
                                pages: []
                            ));
                            _refreshCollections();
                        },
                    ),
                    PopupMenuButton(
                        itemBuilder: (context) => [
                            PopupMenuItem(
                                child: const Text("Manage collections"),
                                onTap: () => context.push("/settings/booru/collections"),
                            )
                        ],
                    )
                ],
            ),
            body: FutureBuilder(
                future: collectionFuture,
                builder: (context, snapshot) {
                    if (snapshot.hasError) {
                        return Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                    const Text("Não foi possível carregar as collections"),
                                    const SizedBox(height: 8),
                                    FilledButton.icon(
                                        onPressed: _refreshCollections,
                                        icon: const Icon(Icons.refresh),
                                        label: const Text("Tentar novamente"),
                                    ),
                                ],
                            ),
                        );
                    }
                    if(!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    return GridView.extent(
                        maxCrossAxisExtent: 250,
                        childAspectRatio: 0.75,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        padding: const EdgeInsets.all(8),
                        children: snapshot.data!.map((collection) {
                            return GestureDetector(
                                onSecondaryTapDown: (tap) => openContextMenu(getOffsetRelativeToBox(offset: tap.globalPosition, renderObject: context.findRenderObject()!), collection),
                                onLongPressDown: (details) => longTap = details,
                                onLongPress: () => openContextMenu(getOffsetRelativeToBox(offset: longTap.globalPosition, renderObject: context.findRenderObject()!), collection),
                                child: CollectionCard(
                                    collection: collection,
                                    booru: widget.booru,
                                    onPressed: () => context.push("/collections/${collection.id}"),
                                    onEdit: () => context.push("/settings/booru/collections?id=${collection.id}"),
                                    onDelete: () => _handleDeleteCollection(collection),
                                ),
                            );
                        }).toList(),
                    );
                }
            ),
        );
    }
}

class CollectionCard extends StatelessWidget {
    const CollectionCard({super.key, required this.collection, required this.booru, this.onPressed, this.onEdit, this.onDelete});

    final BooruCollection collection;
    final Booru booru;
    final void Function()? onPressed;
    final void Function()? onEdit;
    final void Function()? onDelete;

    @override
    Widget build(BuildContext context) {
        return Card(
            clipBehavior: Clip.antiAlias,
            child: Stack(
                children: [
                    Positioned.fill(
                        child: collection.pages.isNotEmpty ? BooruImageLoader(
                            booru: booru,
                            id: collection.pages.first,
                            builder: (context, image) {
                                return Image(
                                    image: FileImage(image.getImage()),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Center(
                                        child: Icon(Icons.broken_image_outlined, size: 48),
                                    ),
                                );
                            }
                        ) : const Center(
                            child: Wrap(
                                direction: Axis.vertical,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                children: [
                                    Icon(Icons.image_not_supported, size: 48,),
                                    Text("No images added", style: TextStyle(fontSize: 16),)
                                ],
                            ),
                        )
                    ),
                    Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                            decoration: BoxDecoration(
                                gradient: LinearGradient(
                                    begin: Alignment.topCenter, 
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black.withOpacity(0.6)]
                                )
                            ),
                            padding: const EdgeInsets.all(8).copyWith(
                                top: 96,
                                bottom: 16
                            ),
                            child: Text(collection.name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                    shadows: [
                                        Shadow(
                                            color: Colors.black,
                                            blurRadius: 5
                                        )
                                    ]
                                ),
                            ),
                        ),
                    ),
                    Material(
                        color: Colors.transparent,
                        child: InkWell(
                            onTap: onPressed,
                        ),
                    ),
                    if (onEdit != null || onDelete != null)
                        Positioned(
                            top: 4,
                            right: 4,
                            child: DecoratedBox(
                                decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    shape: BoxShape.circle,
                                ),
                                child: PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
                                    tooltip: "Collection options",
                                    onSelected: (value) {
                                        if (value == "edit") onEdit?.call();
                                        if (value == "delete") onDelete?.call();
                                    },
                                    itemBuilder: (ctx) => [
                                        if (onEdit != null)
                                            const PopupMenuItem(
                                                value: "edit",
                                                child: Text("Edit collection"),
                                            ),
                                        if (onDelete != null)
                                            PopupMenuItem(
                                                value: "delete",
                                                child: Text(
                                                    "Delete collection",
                                                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                                                ),
                                            ),
                                    ],
                                ),
                            ),
                        ),
                ],
            ),
            // onPressed: () => context.push("/collections/${collection.id}"),
        );
    }
}