import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/components/dialogs/confirm_dialogs.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tempRoot;
    late Directory booruDir;
    late Directory externalDir;

    Future<File> createDummyImage(String dirPath, String filename) async {
        final file = File(p.join(dirPath, filename));
        await file.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10, filename.length]);
        return file;
    }

    Future<File> createDummyThumb(String name) async {
        final thumbFile = File(p.join(booruDir.path, 'thumbnails', name));
        await thumbFile.create(recursive: true);
        await thumbFile.writeAsBytes([255, 216, 255, 224]);
        return thumbFile;
    }

    setUp(() async {
        tempRoot = await Directory.systemTemp.createTemp('localbooru_del_col_test_');
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

    test('removeImage deletes thumbnails (including legacy) and syncs shifted thumbnails', () async {
        final f0 = await createDummyImage(externalDir.path, 'img0.png');
        final f1 = await createDummyImage(externalDir.path, 'img1.png');
        final f2 = await createDummyImage(externalDir.path, 'img2.png');

        await insertImage(PresetImage(image: f0, tags: {'generic': ['t0']}), notify: false);
        await insertImage(PresetImage(image: f1, tags: {'generic': ['t1']}), notify: false);
        await insertImage(PresetImage(image: f2, tags: {'generic': ['t2']}), notify: false);

        final thumb0 = await createDummyThumb('0_img0.jpg');
        final legacyThumb0 = await createDummyThumb('img0.jpg');
        final thumb1 = await createDummyThumb('1_img1.jpg');
        final thumb2 = await createDummyThumb('2_img2.jpg');

        await removeImage('0', notify: false);

        expect(await thumb0.exists(), isFalse, reason: 'Deleted image thumbnail must be removed');
        expect(await legacyThumb0.exists(), isFalse, reason: 'Deleted image legacy thumbnail must be removed');
        expect(await thumb1.exists(), isFalse, reason: 'Old 1_img1.jpg should be renamed to 0_img1.jpg');
        expect(await thumb2.exists(), isFalse, reason: 'Old 2_img2.jpg should be renamed to 1_img2.jpg');

        final syncedThumb0 = File(p.join(booruDir.path, 'thumbnails', '0_img1.jpg'));
        final syncedThumb1 = File(p.join(booruDir.path, 'thumbnails', '1_img2.jpg'));
        expect(await syncedThumb0.exists(), isTrue, reason: 'Shifted image 1 -> 0 must keep its synced thumbnail');
        expect(await syncedThumb1.exists(), isTrue, reason: 'Shifted image 2 -> 1 must keep its synced thumbnail');
    });

    test('removeImages batch deletion deletes all targets without ID-shift corruption and updates collection pages and related', () async {
        final fa = await createDummyImage(externalDir.path, 'a.png');
        final fb = await createDummyImage(externalDir.path, 'b.png');
        final fc = await createDummyImage(externalDir.path, 'c.png');
        final fd = await createDummyImage(externalDir.path, 'd.png');

        await insertImage(PresetImage(image: fa, tags: {'generic': ['a']}), notify: false);
        await insertImage(PresetImage(image: fb, tags: {'generic': ['b']}, relatedImages: ['0', '3']), notify: false);
        await insertImage(PresetImage(image: fc, tags: {'generic': ['c']}), notify: false);
        await insertImage(PresetImage(image: fd, tags: {'generic': ['d']}, relatedImages: ['1', '2']), notify: false);

        final thumbA = await createDummyThumb('0_a.jpg');
        final thumbB = await createDummyThumb('1_b.jpg');
        final thumbC = await createDummyThumb('2_c.jpg');
        final thumbD = await createDummyThumb('3_d.jpg');

        await insertCollection(
            PresetCollection(name: 'BatchCol', pages: ['0', '1', '2', '3']),
            notify: false,
        );

        await removeImages(['0', '2'], notify: false);

        final booru = await getCurrentBooru();
        final remaining = await booru.getRecentImages();
        expect(remaining.length, equals(2));

        final img0 = await booru.getImage('0');
        final img1 = await booru.getImage('1');
        expect(img0, isNotNull);
        expect(img1, isNotNull);
        expect(img0!.filename, equals('b.png'));
        expect(img1!.filename, equals('d.png'));
        expect(await File(img0.path).exists(), isTrue);
        expect(await File(img1.path).exists(), isTrue);
        expect(img0.relatedImages, equals(['1']));
        expect(img1.relatedImages, equals(['0']));

        expect(await File(p.join(booruDir.path, 'files', 'BatchCol', 'a.png')).exists(), isFalse);
        expect(await File(p.join(booruDir.path, 'files', 'BatchCol', 'c.png')).exists(), isFalse);
        expect(await thumbA.exists(), isFalse);
        expect(await thumbC.exists(), isFalse);
        expect(await thumbB.exists(), isFalse);
        expect(await thumbD.exists(), isFalse);
        expect(await File(p.join(booruDir.path, 'thumbnails', '0_b.jpg')).exists(), isTrue);
        expect(await File(p.join(booruDir.path, 'thumbnails', '1_d.jpg')).exists(), isTrue);

        final collections = await booru.getAllCollections();
        expect(collections.length, equals(1));
        expect(collections.first.pages, equals(['0', '1']));
    });

    test('removeCollection with deleteContent=false preserves images in root files and deletes collection folder', () async {
        final f0 = await createDummyImage(externalDir.path, 'p1.png');
        final f1 = await createDummyImage(externalDir.path, 'p2.png');

        await insertImage(PresetImage(image: f0, tags: {'generic': ['p1']}), notify: false);
        await insertImage(PresetImage(image: f1, tags: {'generic': ['p2']}), notify: false);

        final col = await insertCollection(
            PresetCollection(name: 'MyCol', pages: ['0', '1']),
            notify: false,
        );

        final colDir = Directory(p.join(booruDir.path, 'files', 'MyCol'));
        expect(await colDir.exists(), isTrue);
        expect(await File(p.join(colDir.path, 'p1.png')).exists(), isTrue);
        expect(await File(p.join(colDir.path, 'p2.png')).exists(), isTrue);

        await removeCollection(col.id, notify: false, deleteContent: false);

        final booru = await getCurrentBooru();
        expect(await booru.getCollection(col.id), isNull);
        expect(await booru.getAllCollections(), isEmpty);
        expect(await colDir.exists(), isFalse);

        final recent = await booru.getRecentImages();
        expect(recent.length, equals(2));
        expect(await File(p.join(booruDir.path, 'files', 'p1.png')).exists(), isTrue);
        expect(await File(p.join(booruDir.path, 'files', 'p2.png')).exists(), isTrue);
    });

    test('removeCollection with deleteContent=true deletes collection folder, images, metadata, and thumbnails', () async {
        final f0 = await createDummyImage(externalDir.path, 'd1.png');
        final f1 = await createDummyImage(externalDir.path, 'd2.png');
        final fKeep = await createDummyImage(externalDir.path, 'keep.png');

        await insertImage(PresetImage(image: f0, tags: {'generic': ['d1']}), notify: false);
        await insertImage(PresetImage(image: f1, tags: {'generic': ['d2']}), notify: false);
        await insertImage(PresetImage(image: fKeep, tags: {'generic': ['keep']}), notify: false);

        final thumb0 = await createDummyThumb('0_d1.jpg');
        final thumb1 = await createDummyThumb('1_d2.jpg');
        final thumbKeep = await createDummyThumb('2_keep.jpg');

        final col = await insertCollection(
            PresetCollection(name: 'DeleteAllCol', pages: ['0', '1']),
            notify: false,
        );

        final colDir = Directory(p.join(booruDir.path, 'files', 'DeleteAllCol'));
        expect(await colDir.exists(), isTrue);

        await removeCollection(col.id, notify: false, deleteContent: true);

        final booru = await getCurrentBooru();
        expect(await booru.getCollection(col.id), isNull);
        expect(await booru.getAllCollections(), isEmpty);
        expect(await colDir.exists(), isFalse);
        expect(await File(p.join(colDir.path, 'd1.png')).exists(), isFalse);
        expect(await File(p.join(colDir.path, 'd2.png')).exists(), isFalse);
        expect(await thumb0.exists(), isFalse);
        expect(await thumb1.exists(), isFalse);
        expect(await thumbKeep.exists(), isFalse);

        final recent = await booru.getRecentImages();
        expect(recent.length, equals(1));
        expect(recent.first.filename, equals('keep.png'));
        expect(recent.first.id, equals('0'));
        expect(await File(p.join(booruDir.path, 'thumbnails', '0_keep.jpg')).exists(), isTrue);
    });

    test('External deletion of collection folder automatically removes the collection and missing files from booru', () async {
        final f0 = await createDummyImage(externalDir.path, 'ext1.png');
        final fKeep = await createDummyImage(externalDir.path, 'ext_keep.png');

        await insertImage(PresetImage(image: f0, tags: {'generic': ['ext1']}), notify: false);
        await insertImage(PresetImage(image: fKeep, tags: {'generic': ['keep']}), notify: false);

        final thumbExt = await createDummyThumb('0_ext1.jpg');
        final thumbKeep = await createDummyThumb('1_ext_keep.jpg');

        final col = await insertCollection(
            PresetCollection(name: 'ExternalDeletedCol', pages: ['0']),
            notify: false,
        );

        final colDir = Directory(p.join(booruDir.path, 'files', 'ExternalDeletedCol'));
        expect(await colDir.exists(), isTrue);

        // Simulate external deletion of the collection folder
        await colDir.delete(recursive: true);

        final booru = await getCurrentBooru();
        final collections = await booru.getAllCollections();
        expect(collections, isEmpty);
        expect(await booru.getCollection(col.id), isNull);

        final recent = await booru.getRecentImages();
        expect(recent.length, equals(1));
        expect(recent.first.filename, equals('ext_keep.png'));
        expect(recent.first.id, equals('0'));
        expect(await thumbExt.exists(), isFalse);
        expect(await thumbKeep.exists(), isFalse);
        expect(await File(p.join(booruDir.path, 'thumbnails', '0_ext_keep.jpg')).exists(), isTrue);
    });

    testWidgets('DeleteCollectionDialogue offers preserveContent, deleteContent, and Cancelar options', (tester) async {
        DeleteCollectionAction? result;

        Future<void> openDialog() async {
            await tester.pumpWidget(
                MaterialApp(
                    home: Scaffold(
                        body: Builder(
                            builder: (context) => TextButton(
                                onPressed: () async {
                                    result = await showDialog<DeleteCollectionAction>(
                                        context: context,
                                        builder: (_) => const DeleteCollectionDialogue(collectionName: 'MinhaPasta'),
                                    );
                                },
                                child: const Text('Open'),
                            ),
                        ),
                    ),
                ),
            );
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
        }

        // Case 1: Apagar pasta e preservar conteúdo
        await openDialog();
        expect(find.text('Apagar pasta e preservar conteúdo'), findsOneWidget);
        expect(find.text('Apagar pasta e conteúdo'), findsOneWidget);
        expect(find.text('Cancelar'), findsOneWidget);
        await tester.tap(find.text('Apagar pasta e preservar conteúdo'));
        await tester.pumpAndSettle();
        expect(result, equals(DeleteCollectionAction.preserveContent));

        // Case 2: Apagar pasta e conteúdo
        result = null;
        await openDialog();
        await tester.tap(find.text('Apagar pasta e conteúdo'));
        await tester.pumpAndSettle();
        expect(result, equals(DeleteCollectionAction.deleteContent));

        // Case 3: Cancelar
        await openDialog();
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(result, isNull);
    });
}
