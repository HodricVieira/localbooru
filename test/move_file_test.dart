import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/utils/platform_tools.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tempRoot;
    late Directory booruDir;
    late Directory externalDir;

    setUp(() async {
        tempRoot = await Directory.systemTemp.createTemp('localbooru_move_test_');
        booruDir = Directory(p.join(tempRoot.path, 'booru'));
        externalDir = Directory(p.join(tempRoot.path, 'external_source'));
        await booruDir.create(recursive: true);
        await externalDir.create(recursive: true);

        SharedPreferences.setMockInitialValues({
            'booruPath': booruDir.path,
            'file_import_mode': 'copy',
        });

        await createDefaultBooruModel(booruDir.path);
        await setBooru(booruDir.path);
    });

    tearDown(() async {
        currentBooru = null;
        if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
        }
    });

    test('insertImage with moveFile=true deletes original source file', () async {
        final srcFile = File(p.join(externalDir.path, 'test_move.png'));
        await srcFile.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);

        final preset = PresetImage(
            image: srcFile,
            tags: {'generic': ['1girl', 'solo']},
        );

        final inserted = await insertImage(preset, moveFile: true);
        expect(await File(inserted.path).exists(), isTrue);
        expect(await srcFile.exists(), isFalse, reason: 'Original source file must be deleted after move');
    });

    test('insertImage with moveFile=false keeps original source file', () async {
        final srcFile = File(p.join(externalDir.path, 'test_copy.png'));
        await srcFile.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);

        final preset = PresetImage(
            image: srcFile,
            tags: {'generic': ['1girl']},
        );

        final inserted = await insertImage(preset, moveFile: false);
        expect(await File(inserted.path).exists(), isTrue);
        expect(await srcFile.exists(), isTrue, reason: 'Original source file must be kept on copy');
    });

    test('PresetImage preserves originalImage when assigned after empty constructor and compressed', () async {
        final origFile = File(p.join(externalDir.path, 'orig_uncompressed.png'));
        final compressedTemp = File(p.join(tempRoot.path, 'compressed_temp.jpg'));
        await origFile.writeAsBytes([1, 2, 3, 4, 5]);
        await compressedTemp.writeAsBytes([9, 8, 7]);

        // Simulate empty PresetImage() where image is set later and then replaced by compression
        final preset = PresetImage();
        preset.image = origFile;
        expect(preset.originalImage?.path, equals(origFile.path));

        preset.image = compressedTemp;
        expect(preset.originalImage?.path, equals(origFile.path));

        preset.tags = {'generic': ['compressed']};

        final inserted = await insertImage(preset, moveFile: true);
        expect(await File(inserted.path).exists(), isTrue);
        expect(await compressedTemp.exists(), isFalse, reason: 'Compressed temp file must be deleted');
        expect(await origFile.exists(), isFalse, reason: 'Original uncompressed file must also be deleted');
    });

    test('Moving a folder into a collection deletes all source images and empty source directory', () async {
        final folderToMove = Directory(p.join(externalDir.path, 'MangaCap1'));
        await folderToMove.create(recursive: true);

        final img1 = File(p.join(folderToMove.path, '01.jpg'));
        final img2 = File(p.join(folderToMove.path, '02.jpg'));
        final nomedia = File(p.join(folderToMove.path, '.nomedia'));
        await img1.writeAsBytes([10, 20, 30]);
        await img2.writeAsBytes([40, 50, 60]);
        await nomedia.writeAsBytes([]);

        final inserted1 = await insertImage(
            PresetImage(image: img1, tags: {'generic': ['page1']}),
            moveFile: true,
            targetSubfolder: 'MangaCap1',
        );
        final inserted2 = await insertImage(
            PresetImage(image: img2, tags: {'generic': ['page2']}),
            moveFile: true,
            targetSubfolder: 'MangaCap1',
        );

        expect(await File(inserted1.path).exists(), isTrue);
        expect(await File(inserted2.path).exists(), isTrue);
        expect(await img1.exists(), isFalse);
        expect(await img2.exists(), isFalse);

        final folderDeleted = await deleteEmptySourceDirectoryAfterMove(folderToMove);
        expect(folderDeleted, isTrue);
        expect(await folderToMove.exists(), isFalse);
    });
}
