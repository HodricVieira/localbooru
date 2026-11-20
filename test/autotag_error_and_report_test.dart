import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:localbooru/api/index.dart';
import 'package:localbooru/api/preset/index.dart';
import 'package:localbooru/api/tags/index.dart';
import 'package:localbooru/views/image_manager/form.dart';
import 'package:localbooru/views/image_manager/general_collection_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tempRoot;
    late Directory booruDir;

    setUp(() async {
        tempRoot = await Directory.systemTemp.createTemp('localbooru_autotag_report_');
        booruDir = Directory(p.join(tempRoot.path, 'booru'));
        await booruDir.create(recursive: true);

        SharedPreferences.setMockInitialValues({
            'booruPath': booruDir.path,
            'file_import_mode': 'copy',
        });

        await createDefaultBooruModel(booruDir.path);
        await setBooru(booruDir.path);
        await getCurrentBooru();
    });

    tearDown(() async {
        currentBooru = null;
        if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
        }
    });

    group('formatAutoTagErrorMessage', () {
        test('translates SocketException, TimeoutException, and ClientException into friendly Portuguese message', () {
            final socketMsg = formatAutoTagErrorMessage(
                const SocketException("Failed host lookup: 'smilingwolf-wd-tagger.hf.space'"),
            );
            final timeoutMsg = formatAutoTagErrorMessage(
                TimeoutException('Future not completed'),
            );
            final clientMsg = formatAutoTagErrorMessage(
                http.ClientException('Connection closed before full header was received'),
            );

            for (final msg in [socketMsg, timeoutMsg, clientMsg]) {
                expect(msg.toLowerCase(), contains('conexão'));
                expect(msg, isNot(contains('SocketException')));
                expect(msg, isNot(contains('ClientException')));
                expect(msg, isNot(contains('TimeoutException')));
                expect(msg, isNot(contains('errno')));
            }
        });

        test('translates online server failure strings into friendly Portuguese message', () {
            final spaceMsg = formatAutoTagErrorMessage('Upload para WD-Tagger Space falhou (502)');
            final danbooruMsg = formatAutoTagErrorMessage('Danbooru Autotagger falhou (HTTP 503)');
            for (final msg in [spaceMsg, danbooruMsg]) {
                expect(msg.toLowerCase(), contains('indisponível'));
                expect(msg, isNot(contains('502')));
                expect(msg, isNot(contains('503')));
            }
        });

        test('preserves already friendly offline model messages', () {
            const friendlyOffline =
                'O modelo offline (WD ConvNeXt) ainda não foi baixado. Baixe-o nas Configurações ou mude para o modo Automático/Online.';
            expect(formatAutoTagErrorMessage(friendlyOffline), equals(friendlyOffline));
        });
    });

    testWidgets('GeneralCollectionManagerScreen displays tagging report with online, offline, failed counts and friendly error', (tester) async {
        const errorMsg =
            'Sem conexão com a internet durante a geração online. Verifique sua conexão ou baixe um modelo offline nas Configurações.';
        final collection = VirtualPresetCollection(
            name: 'ReportBatch',
            pages: [
                PresetImage(tags: {'generic': ['1girl']}),
            ],
        );

        await tester.pumpWidget(
            MaterialApp(
                home: Scaffold(
                    body: GeneralCollectionManagerScreen(
                        collection: collection,
                        onMultiAutoTag: () {},
                        autoTagReport: const AutoTagReport(
                            onlineSuccessCount: 3,
                            offlineSuccessCount: 5,
                            failedCount: 2,
                            lastErrorMessage: errorMsg,
                        ),
                    ),
                ),
            ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Resumo da geração de tags'), findsOneWidget);
        expect(find.text('Modelo online: 3'), findsOneWidget);
        expect(find.text('Modelo offline: 5'), findsOneWidget);
        expect(find.text('Falharam: 2'), findsOneWidget);
        expect(find.text(errorMsg), findsOneWidget);
    });

    testWidgets('ImageManagerForm displays tagging report in Tags section when autoTagReport is provided', (tester) async {
        await tester.pumpWidget(
            MaterialApp(
                home: Scaffold(
                    body: ImageManagerForm(
                        showRelatedImagesCard: false,
                        preset: PresetImage(
                            tags: {'generic': ['1girl']},
                        ),
                        autoTagReport: const AutoTagReport(
                            onlineSuccessCount: 1,
                            offlineSuccessCount: 0,
                            failedCount: 0,
                        ),
                        onChanged: (_) {},
                    ),
                ),
            ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Resumo da geração de tags'), findsOneWidget);
        expect(find.text('Modelo online: 1'), findsOneWidget);
        expect(find.text('Modelo offline: 0'), findsOneWidget);
        expect(find.text('Falharam: 0'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
    });
}
