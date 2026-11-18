import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/utils/listeners.dart';
import 'package:localbooru/views/image_manager/form.dart';
import 'package:localbooru/views/image_manager/general_collection_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

// Valid 1x1 transparent PNG
final List<int> _validPngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tempRoot;
    late Directory booruDir;
    late File sampleImage1;
    late File sampleImage2;

    setUp(() async {
        tempRoot = await Directory.systemTemp.createTemp('localbooru_tags_vis_');
        booruDir = Directory(p.join(tempRoot.path, 'booru'));
        await booruDir.create(recursive: true);

        sampleImage1 = File(p.join(tempRoot.path, 'sample_1.png'));
        sampleImage2 = File(p.join(tempRoot.path, 'sample_2.png'));
        await sampleImage1.writeAsBytes(_validPngBytes);
        await sampleImage2.writeAsBytes(_validPngBytes);

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

    testWidgets('ImageManagerForm displays initial generated tags and syncs via updateNotifier and didUpdateWidget', (tester) async {
        final notifier = AcessibleNotifyListenerNotifier();
        final preset = PresetImage(
            image: sampleImage1,
            tags: {
                'generic': ['1girl', 'solo'],
                'artist': ['sample_artist'],
                'character': ['sample_char'],
                'copyright': ['sample_series'],
                'species': ['fox'],
            },
        );

        PresetImage latestPreset = preset;

        await tester.pumpWidget(
            MaterialApp(
                home: Scaffold(
                    body: StatefulBuilder(
                        builder: (context, setState) {
                            return ImageManagerForm(
                                preset: latestPreset,
                                updateNotifier: notifier,
                                onChanged: (updated) {
                                    setState(() => latestPreset = updated);
                                },
                            );
                        },
                    ),
                ),
            ),
        );
        await tester.pumpAndSettle();

        // Both TagFields and colored InputChips should display the generated tags
        expect(find.text('1girl solo'), findsOneWidget);
        expect(find.text('1girl'), findsOneWidget);
        expect(find.text('solo'), findsOneWidget);
        expect(find.text('sample_artist'), findsNWidgets(2));
        expect(find.text('sample_char'), findsNWidgets(2));
        expect(find.text('sample_series'), findsNWidgets(2));
        expect(find.text('fox'), findsNWidgets(2));

        // Simulate in-place batch autotag mutation + updateNotifier notification
        latestPreset.tags = {
            'generic': ['blue_eyes', 'smile'],
            'artist': [],
            'character': ['heroine'],
            'copyright': [],
            'species': [],
        };
        notifier.update();
        await tester.pumpAndSettle();

        expect(find.text('blue_eyes smile'), findsOneWidget);
        expect(find.text('blue_eyes'), findsOneWidget);
        expect(find.text('smile'), findsOneWidget);
        expect(find.text('heroine'), findsNWidgets(2));

        // Simulate receiving a new PresetImage via didUpdateWidget
        final nextPreset = PresetImage(
            image: sampleImage1,
            tags: {
                'generic': ['night_sky', 'moonlight'],
                'artist': [],
                'character': [],
                'copyright': [],
                'species': [],
            },
        );
        await tester.pumpWidget(
            MaterialApp(
                home: Scaffold(
                    body: ImageManagerForm(
                        preset: nextPreset,
                        updateNotifier: notifier,
                        onChanged: (_) {},
                    ),
                ),
            ),
        );
        await tester.pumpAndSettle();

        expect(find.text('night_sky moonlight'), findsOneWidget);
        expect(find.text('night_sky'), findsOneWidget);
        expect(find.text('moonlight'), findsOneWidget);

        // Removing a tag chip updates both the chips and the TagField
        final nightSkyChip = find.ancestor(
            of: find.text('night_sky'),
            matching: find.byType(InputChip),
        );
        final deleteIcon = find.descendant(
            of: nightSkyChip,
            matching: find.byIcon(Icons.close),
        );
        await tester.ensureVisible(deleteIcon);
        await tester.tap(deleteIcon);
        await tester.pumpAndSettle();

        expect(find.text('night_sky'), findsNothing);
        expect(find.text('moonlight'), findsNWidgets(2));
    });

    testWidgets('GeneralCollectionManagerScreen renders generated tags for each batch image and handles tap', (tester) async {
        int? selectedIndex;
        final collection = VirtualPresetCollection(
            name: 'BatchTest',
            pages: [
                PresetImage(
                    image: sampleImage1,
                    rating: Rating.safe,
                    tags: {
                        'generic': ['1girl', 'long_hair'],
                        'artist': ['artist_a'],
                        'character': ['char_a'],
                        'copyright': [],
                        'species': [],
                    },
                ),
                PresetImage(
                    image: sampleImage2,
                    tags: {
                        'generic': ['scenery', 'clouds'],
                        'artist': [],
                        'character': [],
                        'copyright': ['orig_work'],
                        'species': [],
                    },
                ),
            ],
        );

        await tester.pumpWidget(
            MaterialApp(
                home: Scaffold(
                    body: GeneralCollectionManagerScreen(
                        collection: collection,
                        onSelectImagePage: (idx) => selectedIndex = idx,
                    ),
                ),
            ),
        );
        await tester.pumpAndSettle();

        final scrollable = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(find.text('1. sample_1.png'), 200, scrollable: scrollable);
        await tester.pumpAndSettle();

        expect(find.text('Generated Tags by Image (2)'), findsOneWidget);
        expect(find.text('1. sample_1.png'), findsOneWidget);
        expect(find.text('1girl'), findsOneWidget);
        expect(find.text('long_hair'), findsOneWidget);
        expect(find.text('artist_a'), findsOneWidget);
        expect(find.text('char_a'), findsOneWidget);

        await tester.scrollUntilVisible(find.text('2. sample_2.png'), 200, scrollable: scrollable);
        await tester.pumpAndSettle();

        expect(find.text('2. sample_2.png'), findsOneWidget);
        expect(find.text('scenery'), findsOneWidget);
        expect(find.text('clouds'), findsOneWidget);
        expect(find.text('orig_work'), findsOneWidget);

        await tester.ensureVisible(find.text('2. sample_2.png'));
        await tester.tap(find.text('2. sample_2.png'));
        await tester.pump();
        expect(selectedIndex, equals(1));
    });
}
