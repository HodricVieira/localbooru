part of tag_manager;

typedef AccuracyTagList = Map<String, double>;

class WaifuTaggerModelInfo {
    const WaifuTaggerModelInfo({
        required this.id,
        required this.name,
        required this.description,
        required this.onnxUrl,
        required this.tagsUrl,
        required this.onnxFilename,
        required this.tagsFilename,
        required this.hfRepo,
        required this.sizeHint,
    });

    final String id;
    final String name;
    final String description;
    final String onnxUrl;
    final String tagsUrl;
    final String onnxFilename;
    final String tagsFilename;
    final String hfRepo;
    final String sizeHint;
}

const List<WaifuTaggerModelInfo> availableWaifuTaggerModels = [
    WaifuTaggerModelInfo(
        id: "wd-convnext-v3-mobile",
        name: "WD ConvNeXt Tagger v3 (WaifuTagger Mobile INT8)",
        description: "Leve e rápido para Android (~95 MB) - usado no WaifuTagger",
        onnxUrl: "https://huggingface.co/Smashinfries/wd-convnext-tagger-v3-onnx-mobile/resolve/main/wd-convnext-tagger-v3-quint8-mobile.onnx",
        tagsUrl: "https://huggingface.co/Smashinfries/wd-convnext-tagger-v3-onnx-mobile/resolve/main/tags.json",
        onnxFilename: "wd-convnext-tagger-v3-quint8-mobile.onnx",
        tagsFilename: "wd-convnext-tagger-v3-tags.json",
        hfRepo: "SmilingWolf/wd-convnext-tagger-v3",
        sizeHint: "~95 MB",
    ),
    WaifuTaggerModelInfo(
        id: "wd-swinv2-v3-mobile",
        name: "WD SwinV2 Tagger v3 (WaifuTagger Mobile INT8)",
        description: "Alta precisão em anime/ilustrações (~115 MB) - usado no WaifuTagger",
        onnxUrl: "https://huggingface.co/Smashinfries/wd-swinv2-tagger-v3-onnx-mobile/resolve/main/wd-swinv2-tagger-v3-quint8-mobile.onnx",
        tagsUrl: "https://huggingface.co/Smashinfries/wd-swinv2-tagger-v3-onnx-mobile/resolve/main/tags.json",
        onnxFilename: "wd-swinv2-tagger-v3-quint8-mobile.onnx",
        tagsFilename: "wd-swinv2-tagger-v3-tags.json",
        hfRepo: "SmilingWolf/wd-swinv2-tagger-v3",
        sizeHint: "~115 MB",
    ),
    WaifuTaggerModelInfo(
        id: "wd-vit-v3",
        name: "WD ViT Tagger v3 (Standard FP32)",
        description: "Modelo completo Vision Transformer v3 (~360 MB)",
        onnxUrl: "https://huggingface.co/SmilingWolf/wd-vit-tagger-v3/resolve/main/model.onnx",
        tagsUrl: "https://huggingface.co/SmilingWolf/wd-vit-tagger-v3/resolve/main/selected_tags.csv",
        onnxFilename: "wd-vit-tagger-v3.onnx",
        tagsFilename: "wd-vit-tagger-v3-tags.csv",
        hfRepo: "SmilingWolf/wd-vit-tagger-v3",
        sizeHint: "~360 MB",
    ),
];

WaifuTaggerModelInfo getWaifuTaggerModelById(String? id) {
    return availableWaifuTaggerModels.firstWhere(
        (m) => m.id == id,
        orElse: () => availableWaifuTaggerModels.first,
    );
}

class AutoTagDetailedResult {
    AutoTagDetailedResult({
        required this.allTags,
        required this.separatedTags,
        this.rating,
    });

    final AccuracyTagList allTags;
    final Map<String, List<String>> separatedTags;
    final Rating? rating;
}

class _TagVocabEntry {
    _TagVocabEntry({required this.name, required this.category});
    final String name;
    final int category; // 0: general, 1: artist, 3: copyright, 4: character, 5: meta, 9: rating
}

const MethodChannel _waifuTaggerChannel = MethodChannel('com.auser.localbooru/waifutagger');

Future<Directory> getWaifuTaggerModelDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, "waifutagger_models"));
    if (!await dir.exists()) {
        await dir.create(recursive: true);
    }
    return dir;
}

Future<bool> isWaifuTaggerModelDownloaded(WaifuTaggerModelInfo model) async {
    final dir = await getWaifuTaggerModelDirectory();
    final onnxFile = File(p.join(dir.path, model.onnxFilename));
    final tagsFile = File(p.join(dir.path, model.tagsFilename));
    return await onnxFile.exists() && await tagsFile.exists() && await onnxFile.length() > 1024;
}

Future<void> deleteWaifuTaggerModel(WaifuTaggerModelInfo model) async {
    final dir = await getWaifuTaggerModelDirectory();
    final onnxFile = File(p.join(dir.path, model.onnxFilename));
    final tagsFile = File(p.join(dir.path, model.tagsFilename));
    if (await onnxFile.exists()) await onnxFile.delete();
    if (await tagsFile.exists()) await tagsFile.delete();
    if (Platform.isAndroid) {
        try {
            await _waifuTaggerChannel.invokeMethod('releaseModel');
        } catch (_) {}
    }
}

Future<void> downloadWaifuTaggerModel(
    WaifuTaggerModelInfo model, {
    void Function(double progress, String status)? onProgress,
}) async {
    final dir = await getWaifuTaggerModelDirectory();
    final onnxPath = p.join(dir.path, model.onnxFilename);
    final tagsPath = p.join(dir.path, model.tagsFilename);

    onProgress?.call(0.0, "Baixando lista de tags (${model.tagsFilename})...");
    await _downloadFileWithProgress(model.tagsUrl, tagsPath, (p) {
        onProgress?.call(p * 0.05, "Baixando lista de tags...");
    });

    onProgress?.call(0.05, "Baixando modelo (${model.sizeHint})...");
    await _downloadFileWithProgress(model.onnxUrl, onnxPath, (p) {
        onProgress?.call(0.05 + (p * 0.95), "Baixando modelo: ${(p * 100).toStringAsFixed(0)}%");
    });

    onProgress?.call(1.0, "Concluído!");
}

Future<void> _downloadFileWithProgress(String url, String savePath, void Function(double) onProgress) async {
    final client = http.Client();
    try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
            throw "Falha ao baixar $url (HTTP ${response.statusCode})";
        }
        final totalBytes = response.contentLength ?? 0;
        int receivedBytes = 0;
        final tempFile = File("$savePath.tmp");
        final sink = tempFile.openWrite();
        await for (final chunk in response.stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            if (totalBytes > 0) {
                onProgress(receivedBytes / totalBytes);
            }
        }
        await sink.close();
        if (await File(savePath).exists()) {
            await File(savePath).delete();
        }
        await tempFile.rename(savePath);
    } finally {
        client.close();
    }
}

String _normalizeTag(String rawTag) {
    return rawTag.trim().replaceAll(" ", "_");
}

String? _cachedVocabPath;
List<_TagVocabEntry>? _cachedVocabEntries;

Future<List<_TagVocabEntry>> _loadModelVocabulary(File tagsFile) async {
    if (_cachedVocabPath == tagsFile.path && _cachedVocabEntries != null) {
        return _cachedVocabEntries!;
    }
    final content = await tagsFile.readAsString();
    List<_TagVocabEntry> ResultEntries;
    if (tagsFile.path.endsWith(".json")) {
        final Map<String, dynamic> decoded = jsonDecode(content);
        final List<_TagVocabEntry> entries = List.generate(
            decoded.length,
            (_) => _TagVocabEntry(name: "", category: 0),
        );
        decoded.forEach((key, value) {
            final idx = int.tryParse(key);
            if (idx != null && idx >= 0 && idx < entries.length && value is List && value.length >= 2) {
                entries[idx] = _TagVocabEntry(
                    name: _normalizeTag(value[0].toString()),
                    category: int.tryParse(value[1].toString()) ?? 0,
                );
            }
        });
        ResultEntries = entries;
    } else {
        // selected_tags.csv format: tag_id,name,category,count
        final lines = const LineSplitter().convert(content);
        final List<_TagVocabEntry> entries = [];
        for (int i = 1; i < lines.length; i++) {
            final line = lines[i].trim();
            if (line.isEmpty) continue;
            final parts = line.split(",");
            if (parts.length >= 3) {
                entries.add(_TagVocabEntry(
                    name: _normalizeTag(parts[1]),
                    category: int.tryParse(parts[2]) ?? 0,
                ));
            }
        }
        ResultEntries = entries;
    }
    _cachedVocabPath = tagsFile.path;
    _cachedVocabEntries = ResultEntries;
    return ResultEntries;
}

Rating? _mapWdRating(Map<String, double> ratingScores) {
    if (ratingScores.isEmpty) return null;
    final topEntry = ratingScores.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return switch (topEntry.key) {
        "general" || "safe" => Rating.safe,
        "sensitive" => Rating.safe,
        "questionable" => Rating.questionable,
        "explicit" => Rating.explicit,
        _ => null,
    };
}

Future<AutoTagDetailedResult> autoTagDetailed(File file, {double? threshold}) async {
    final prefs = await SharedPreferences.getInstance();
    final double filterThreshold = threshold ?? (prefs.getDouble("autotag_accuracy") ?? settingsDefaults["autotag_accuracy"]);
    final String selectedModelId = prefs.getString("autotag_model") ?? settingsDefaults["autotag_model"];
    final String mode = prefs.getString("autotag_mode") ?? settingsDefaults["autotag_mode"]; // "auto", "offline", "online"
    final modelInfo = getWaifuTaggerModelById(selectedModelId);

    AutoTagDetailedResult? result;

    // 1. Try Offline ONNX inference on Android if downloaded and mode != "online"
    if (Platform.isAndroid && mode != "online") {
        if (await isWaifuTaggerModelDownloaded(modelInfo)) {
            try {
                result = await _runOfflineWaifuTagger(file, modelInfo, filterThreshold);
            } catch (e) {
                debugPrint("Offline WaifuTagger error: $e");
                if (mode == "offline") rethrow;
            }
        } else if (mode == "offline") {
            throw "O modelo offline (${modelInfo.name}) ainda não foi baixado. Baixe-o nas Configurações ou mude para o modo Automático/Online.";
        }
    }

    // 2. Fallback to Online WaifuTagger / SmilingWolf WD-Tagger Gradio Space API
    if (result == null) {
        try {
            result = await _runOnlineWdTaggerSpace(file, modelInfo, filterThreshold);
        } catch (e) {
            debugPrint("Online WD-Tagger Space failed ($e), falling back to Danbooru Autotagger...");
            result = await _runDanbooruFallback(file, filterThreshold);
        }
    }

    return result;
}

Future<AutoTagDetailedResult> _runOfflineWaifuTagger(
    File imageFile,
    WaifuTaggerModelInfo modelInfo,
    double filterThreshold,
) async {
    final dir = await getWaifuTaggerModelDirectory();
    final onnxPath = p.join(dir.path, modelInfo.onnxFilename);
    final tagsFile = File(p.join(dir.path, modelInfo.tagsFilename));

    final vocab = await _loadModelVocabulary(tagsFile);
    final List<dynamic>? rawProbs = await _waifuTaggerChannel.invokeMethod<List<dynamic>>(
        'runInference',
        {
            'modelPath': onnxPath,
            'imagePath': imageFile.path,
        },
    );

    if (rawProbs == null || rawProbs.isEmpty) {
        throw "O modelo ONNX retornou resultado vazio.";
    }

    final AccuracyTagList allTags = {};
    final Map<String, double> ratingScores = {};
    final Map<String, List<String>> separated = {
        "generic": [],
        "artist": [],
        "character": [],
        "copyright": [],
        "species": [],
    };

    final int count = rawProbs.length < vocab.length ? rawProbs.length : vocab.length;
    for (int i = 0; i < count; i++) {
        final double prob = (rawProbs[i] as num).toDouble();
        final entry = vocab[i];
        if (entry.name.isEmpty || Metatag.isMetatag(entry.name)) continue;

        if (entry.category == 9) {
            ratingScores[entry.name] = prob;
            continue;
        }

        allTags[entry.name] = prob;
        if (prob >= filterThreshold) {
            switch (entry.category) {
                case 1:
                    separated["artist"]!.add(entry.name);
                case 3:
                    separated["copyright"]!.add(entry.name);
                case 4:
                    separated["character"]!.add(entry.name);
                default:
                    separated["generic"]!.add(entry.name);
            }
        }
    }

    // Also cross-check with current booru's known tag types for generic tags
    try {
        final booru = await getCurrentBooru();
        final reseparated = await booru.separateTagsByType(separated["generic"]!);
        separated["generic"] = reseparated["generic"] ?? [];
        for (final key in ["artist", "character", "copyright", "species"]) {
            if (reseparated[key] != null) {
                for (final t in reseparated[key]!) {
                    if (!separated[key]!.contains(t)) separated[key]!.add(t);
                }
            }
        }
    } catch (_) {}

    return AutoTagDetailedResult(
        allTags: allTags,
        separatedTags: separated,
        rating: _mapWdRating(ratingScores),
    );
}

Future<AutoTagDetailedResult> _runOnlineWdTaggerSpace(
    File file,
    WaifuTaggerModelInfo modelInfo,
    double filterThreshold,
) async {
    const String baseUrl = "https://smilingwolf-wd-tagger.hf.space";

    // Step 1: Upload file to Gradio Space
    final uploadReq = http.MultipartRequest("POST", Uri.parse("$baseUrl/gradio_api/upload"));
    uploadReq.files.add(http.MultipartFile.fromBytes(
        "files",
        await file.readAsBytes(),
        filename: p.basename(file.path),
    ));
    final uploadRes = await http.Response.fromStream(
        await uploadReq.send().timeout(const Duration(seconds: 30)),
    );
    if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
        throw "Upload para WD-Tagger Space falhou (${uploadRes.statusCode})";
    }
    final List<dynamic> uploadedPaths = jsonDecode(uploadRes.body);
    if (uploadedPaths.isEmpty) throw "Nenhum caminho retornado pelo WD-Tagger Space";
    final String remotePath = uploadedPaths.first.toString();

    // Step 2: Call predict endpoint
    final callRes = await http.post(
        Uri.parse("$baseUrl/gradio_api/call/predict"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
            "data": [
                {
                    "path": remotePath,
                    "meta": {"_type": "gradio.FileData"}
                },
                modelInfo.hfRepo,
                filterThreshold,
                false,
                filterThreshold,
                false
            ]
        }),
    ).timeout(const Duration(seconds: 30));

    if (callRes.statusCode < 200 || callRes.statusCode >= 300) {
        throw "Chamada predict falhou (${callRes.statusCode})";
    }
    final String eventId = jsonDecode(callRes.body)["event_id"];

    // Step 3: Read SSE result stream
    final sseRes = await http.get(
        Uri.parse("$baseUrl/gradio_api/call/predict/$eventId"),
    ).timeout(const Duration(seconds: 45));

    List<dynamic>? dataPayload;
    for (final line in const LineSplitter().convert(sseRes.body)) {
        if (line.startsWith("data: ")) {
            final jsonPart = line.substring(6).trim();
            if (jsonPart.isNotEmpty && jsonPart != "null") {
                final decoded = jsonDecode(jsonPart);
                if (decoded is List) {
                    dataPayload = decoded;
                }
            }
        }
    }

    if (dataPayload == null || dataPayload.length < 4) {
        throw "Resposta inválida do WD-Tagger Space";
    }

    // dataPayload: [output_text, rating_confidences, character_confidences, general_confidences]
    final AccuracyTagList allTags = {};
    final Map<String, double> ratingScores = {};
    final Map<String, List<String>> separated = {
        "generic": [],
        "artist": [],
        "character": [],
        "copyright": [],
        "species": [],
    };

    void parseConfidenceObject(dynamic obj, String targetCategory) {
        if (obj is Map && obj["confidences"] is List) {
            for (final item in obj["confidences"]) {
                if (item is Map && item["label"] != null && item["confidence"] != null) {
                    final String tag = _normalizeTag(item["label"].toString());
                    final double conf = (item["confidence"] as num).toDouble();
                    if (tag.isEmpty || Metatag.isMetatag(tag)) continue;
                    if (targetCategory == "rating") {
                        ratingScores[tag] = conf;
                    } else {
                        allTags[tag] = conf;
                        if (conf >= filterThreshold) {
                            separated[targetCategory]!.add(tag);
                        }
                    }
                }
            }
        }
    }

    parseConfidenceObject(dataPayload[1], "rating");
    parseConfidenceObject(dataPayload[2], "character");
    parseConfidenceObject(dataPayload[3], "generic");

    try {
        final booru = await getCurrentBooru();
        final reseparated = await booru.separateTagsByType(separated["generic"]!);
        separated["generic"] = reseparated["generic"] ?? [];
        for (final key in ["artist", "character", "copyright", "species"]) {
            if (reseparated[key] != null) {
                for (final t in reseparated[key]!) {
                    if (!separated[key]!.contains(t)) separated[key]!.add(t);
                }
            }
        }
    } catch (_) {}

    return AutoTagDetailedResult(
        allTags: allTags,
        separatedTags: separated,
        rating: _mapWdRating(ratingScores),
    );
}

Future<AutoTagDetailedResult> _runDanbooruFallback(File file, double filterThreshold) async {
    http.MultipartRequest req = http.MultipartRequest("POST", Uri.parse("https://autotagger.donmai.us/evaluate"));
    req.headers['Content-Type'] = 'application/json; charset=UTF-8';
    req.files.add(http.MultipartFile.fromBytes("file", await file.readAsBytes(), filename: p.basename(file.path)));
    req.fields["format"] = "json";
    http.Response response = await http.Response.fromStream(await req.send());

    final AccuracyTagList tags = AccuracyTagList.from(jsonDecode(response.body)[0]["tags"])
        ..removeWhere((tag, _) => Metatag.isMetatag(tag));
    final filtered = filterAccurateResults(tags, filterThreshold);
    final booru = await getCurrentBooru();
    final separated = await booru.separateTagsByType(filtered.keys.toList());

    return AutoTagDetailedResult(
        allTags: tags,
        separatedTags: {
            "generic": separated["generic"] ?? [],
            "artist": separated["artist"] ?? [],
            "character": separated["character"] ?? [],
            "copyright": separated["copyright"] ?? [],
            "species": separated["species"] ?? [],
        },
    );
}

Future<AccuracyTagList> autoTag(File file) async {
    final res = await autoTagDetailed(file, threshold: 0.0);
    return res.allTags;
}

AccuracyTagList filterAccurateResults(AccuracyTagList tags, double filterPercentage) {
    return AccuracyTagList.from(tags)..removeWhere((tag, accuracy) => accuracy < filterPercentage);
}
