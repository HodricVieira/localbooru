import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/views/image_manager/shell.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

const setupScreenText = """
This is where you select or create a new booru folder.

If you already have one, select the first option to open the file manager and select it.

If you don't, click the "Create a new one" option, create a new folder on a desired location and select it. It will create the necessary files to host the content of your image repository, a.k.a. a Booru
""";

class SetBooruScreen extends StatelessWidget{
    const SetBooruScreen({super.key});

    @override
    Widget build(BuildContext context) {
        Orientation orientation = MediaQuery.of(context).orientation;

        return Scaffold (
            appBar: AppBar(),
            body: Center(
                child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Flex(
                        direction: orientation == Orientation.portrait ? Axis.vertical : Axis.horizontal,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: orientation == Orientation.portrait ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                        children: [
                            Flexible(
                                flex: 1,
                                child: Text(setupScreenText, textAlign: orientation == Orientation.landscape ? TextAlign.center: null,)
                            ),
                            SizedBox(
                                height: orientation == Orientation.portrait ? 32 : null,
                                width: orientation == Orientation.landscape ? 64 : null
                            ),
                            Flexible(
                                flex: 1,
                                child: Wrap(
                                    direction: Axis.vertical,
                                    alignment: WrapAlignment.center,
                                    crossAxisAlignment: orientation == Orientation.landscape ? WrapCrossAlignment.center : WrapCrossAlignment.start,
                                    spacing: 16.0,
                                    children: [
                                        OutlinedButton.icon(
                                            label: const Text("Select an already existing booru"),
                                            icon: const Icon(Icons.folder),
                                            onPressed: () async {
                                                String? output = await FilePicker.platform.getDirectoryPath();
                                                if(output == null) return;
                                                final File repoinfo = File(p.join(output, "repoinfo.json"));
                                                if(!(await repoinfo.exists() && await Directory(p.join(output, "files")).exists())) {
                                                    if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("This booru either does not contain repoinfo.json or the files folder. Please pick a valid booru")));
                                                    return;
                                                }
                                                try{
                                                    final Map<String, dynamic> raw = jsonDecode(await repoinfo.readAsString());
                                                    if(!isValidBooruModel(raw)) throw "it doesn't contain valid props";
                                                } catch(e) {
                                                    if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("repoinfo.json is corrupted, please fix it")));
                                                    return;
                                                }
                                                await setBooru(output);
                                                if (context.mounted) context.go("/home");
                                            },
                                        ),
                                        FilledButton.icon(
                                            label: const Text("Create a new one"),
                                            icon: const Icon(Icons.add),
                                            onPressed: () async {
                                                String? output = await FilePicker.platform.getDirectoryPath();
                                                if(output == null) return;

                                                // Check if folder already contains loose images before creating subfolders
                                                final dir = Directory(output);
                                                final List<File> existingImages = [];
                                                await for (final entity in dir.list(recursive: false, followLinks: false)) {
                                                    if (entity is File) {
                                                        final mime = lookupMimeType(entity.path);
                                                        if (mime != null && mime.startsWith("image/")) {
                                                            existingImages.add(entity);
                                                        }
                                                    }
                                                }
                                                existingImages.sort((a, b) => a.path.compareTo(b.path));

                                                await createDefaultBooruModel(output);
                                                await setBooru(output);

                                                if (!context.mounted) return;
                                                if (existingImages.isNotEmpty) {
                                                    final shouldImport = await showDialog<bool>(
                                                        context: context,
                                                        builder: (ctx) => AlertDialog(
                                                            title: const Text("Images found in folder"),
                                                            content: Text("Found ${existingImages.length} image(s) in this folder. Would you like to import and auto-tag them with WaifuTagger now?"),
                                                            actions: [
                                                                TextButton(
                                                                    onPressed: () => Navigator.of(ctx).pop(false),
                                                                    child: const Text("Skip"),
                                                                ),
                                                                FilledButton.icon(
                                                                    onPressed: () => Navigator.of(ctx).pop(true),
                                                                    icon: const Icon(CupertinoIcons.sparkles),
                                                                    label: const Text("Import & Auto-Tag"),
                                                                ),
                                                            ],
                                                        ),
                                                    );
                                                    if (shouldImport == true && context.mounted) {
                                                        final presets = existingImages.map((f) => PresetImage(image: f, key: UniqueKey())).toList();
                                                        context.go("/home");
                                                        context.push("/manage_image", extra: PresetListManageImageSendable(presets, autoTagOnStart: true));
                                                        return;
                                                    }
                                                }
                                                if (context.mounted) context.go("/home");
                                            },
                                        )
                                    ],
                                ),
                            )
                        ],
                    ),
                )
            )
        );
    }
}
