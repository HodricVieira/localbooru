import 'package:flutter/material.dart';
import 'package:localbooru/api/index.dart';

class DeleteImageDialogue extends StatelessWidget {
    const DeleteImageDialogue({super.key});

    @override
    Widget build(BuildContext context) {
        return AlertDialog(
            title: const Text("Delete image"),
            content: const Text("Are you sure that you want to delete this image? This action will be irreversible"),
            actions: [
                TextButton(onPressed: Navigator.of(context).pop, child: const Text("No")),
                TextButton(
                    child: const Text("Yes"), 
                    onPressed: () => Navigator.of(context).pop(true)
                ),
            ],
        );
    }
}

class UnsavedChangesDialogue extends StatelessWidget {
    const UnsavedChangesDialogue({super.key});

    @override
    Widget build(BuildContext context) {
        return AlertDialog(
            title: const Text("Unsaved changes"),
            content: const Text("You have unsaved changes. Do you want to discard the changes and exit?"),
            actions: [
                TextButton(
                    child: const Text("Yes"), 
                    onPressed: () => Navigator.of(context).pop(true)
                ),
                TextButton(onPressed: Navigator.of(context).pop, child: const Text("No")),
            ],
        );
    }
}

enum DeleteCollectionAction { preserveContent, deleteContent }

class DeleteCollectionDialogue extends StatelessWidget {
    const DeleteCollectionDialogue({super.key, this.collectionName});

    final String? collectionName;

    @override
    Widget build(BuildContext context) {
        return AlertDialog(
            title: const Text("Excluir collection"),
            content: Text(
                collectionName != null
                    ? "Escolha o que fazer com a pasta e as imagens da collection \"$collectionName\":"
                    : "Escolha o que fazer com a pasta e as imagens desta collection:"
            ),
            actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text("Cancelar"),
                ),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(DeleteCollectionAction.preserveContent),
                    child: const Text("Apagar pasta e preservar conteúdo"),
                ),
                TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: () => Navigator.of(context).pop(DeleteCollectionAction.deleteContent),
                    child: const Text("Apagar pasta e conteúdo"),
                ),
            ],
        );
    }
}

Future<bool> confirmAndDeleteCollection(BuildContext context, BooruCollection collection) async {
    final action = await showDialog<DeleteCollectionAction>(
        context: context,
        builder: (ctx) => DeleteCollectionDialogue(collectionName: collection.name),
    );
    if (action == null) return false;
    await removeCollection(
        collection.id,
        deleteContent: action == DeleteCollectionAction.deleteContent,
    );
    return true;
}