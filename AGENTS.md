# AGENTS.md — Guia para Agentes e Desenvolvedores

Este documento orienta agentes de IA e desenvolvedores que trabalham neste fork do **LocalBooru** (Flutter / Dart + Android nativo em Kotlin).

---

## 1. Visão Geral do Projeto

Fork do [LocalBooru](https://github.com/resucutie/localbooru) adaptado com foco em uso **Android offline-first**, incluindo:
- **Auto-tagging local (ONNX Runtime no Android)** com modelos do projeto **WaifuTagger / WD Tagger v3** e fallback online.
- **Importação e auto-tagging em lote por pasta**, com opção de **Copiar ou Mover** arquivos e preservar a pasta como uma **Collection** dentro de `booru/files/<collection>/`.
- **Galeria com navegação por deslize horizontal (swipe)** na visualização e no zoom de imagens.

---

## 2. Stack e Ambiente

- **Flutter:** `3.27.3` (canal `stable`, ver `.github/workflows/flutter-deploy.yaml`)
- **Dart SDK:** `>=3.2.6 <4.0.0` (`pubspec.yaml`)
- **Android:** `compileSdkVersion 34`, `minSdkVersion 23`, Kotlin `2.0.21`, Java 17
- **ONNX Runtime Android:** `com.microsoft.onnxruntime:onnxruntime-android:1.20.0` (`android/app/build.gradle`)
- **Roteamento:** `go_router ^14.1.2`

### Comandos úteis
```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```
> **CI/CD:** O workflow `.github/workflows/flutter-deploy.yaml` compila automaticamente para Linux, Windows e Android (`flutter build apk --release`) em todo `push`. Se os secrets de keystore não estiverem configurados no repositório, o APK release assinado com chave de debug é publicado como artifact `localbooru-android-apk`.

---

## 3. Mapa de Arquivos Principais

| Caminho | Responsabilidade |
| :--- | :--- |
| `lib/main.dart` | Inicialização do app, tema Material 3, intent de compartilhamento e `SafeBackButtonDispatcher`. |
| `lib/routing.dart` | Configuração do `GoRouter` e rotas (`/home`, `/search`, `/view/:id`, `/zoom_image/:id`, `/collections`, `/manage_image`, `/settings`). |
| `lib/api/index.dart` | Ponto de entrada da API local (`getCurrentBooru`, `setBooru`, `createDefaultBooruModel`). |
| `lib/api/readable.dart` | Leitura de `repoinfo.json`, resolução de caminhos (`files/...`), busca por tags e collections (`Booru`, `BooruImage`, `BooruCollection`). |
| `lib/api/writable.dart` | Escrita atômica em `repoinfo.json`, `insertImage` (copiar/mover + subpasta), `insertCollection` (sincronização de pastas), `addImagesToCollection`, `removeImage`, `removeCollection`. |
| `lib/api/preset/image.dart` | Modelo `PresetImage` (inclui `originalImage` para limpeza segura após compressão em modo *Mover*). |
| `lib/api/tags/autotag.dart` | Gerenciamento de modelos WaifuTagger (download, cache de vocabulário, inferência offline via `MethodChannel` e fallback online). |
| `lib/api/tags/match.dart` | Filtro de busca por tags, metatags (`rating:`, `id:`, `type:`, `file:`, `collection:`). |
| `lib/utils/compressor.dart` | Geração e cache de thumbnails (`thumbnails/`) e compressão de imagens. |
| `lib/utils/constants.dart` | Padrões de configuração (`settingsDefaults`), formatos suportados e cores/ícones de tags. |
| `lib/components/image_grid_display.dart` | Grade de miniaturas (`SliverRepoGrid` e `ImageGrid`). |
| `lib/views/image_manager/shell.dart` | Fluxo de adição/edição individual e em lote, seleção de pasta, auto-tag em lote e criação/adição em collections. |
| `lib/views/image_manager/form.dart` | Formulário individual de imagem (preview, tags por categoria, rating, mover/copiar, collection destino). |
| `lib/views/image_manager/general_collection_manager.dart` | Tela de gerenciamento em lote (preservar pasta como collection, mover/copiar, relacionar imagens, auto-tag/compressão em lote). |
| `lib/views/navigation/image_view.dart` | Visualização de imagem com `GallerySwipeView` (`PageView.builder`) e metadados. |
| `lib/views/navigation/zoomed_view.dart` | Visualização em tela cheia com zoom (`PhotoView`) e swipe entre imagens. |
| `lib/views/settings/overall_settings.dart` | Configurações gerais, seleção/download de modelo WaifuTagger, modo de execução e ação padrão de arquivo (*Copy*/*Move*). |
| `android/app/src/main/kotlin/com/example/localbooru/MainActivity.kt` | Canal nativo `com.auser.localbooru/waifutagger` com `OrtEnvironment` / `OrtSession`. |
| `android/app/proguard-rules.pro` | Regras ProGuard/R8 obrigatórias para preservar classes JNI de `ai.onnxruntime.**` em builds `--release`. |
| `android/app/src/main/AndroidManifest.xml` | Permissões de armazenamento, `android:largeHeap="true"` e `android:enableOnBackInvokedCallback="false"`. |

---

## 4. Regras Críticas e Armadilhas Conhecidas (NÃO QUEBRAR)

### 4.1. ONNX Runtime no Android (`MainActivity.kt` & R8)
- **ProGuard / R8:** Builds `--release` usam R8. Nunca remova `android/app/proguard-rules.pro` nem a referência em `android/app/build.gradle`. Sem `-keep class ai.onnxruntime.** { *; }`, o C++ JNI do ONNX Runtime sofre `SIGABRT` em runtime.
- **SessionOptions para modelos quantizados (`*-quint8-mobile.onnx`):**
  - Mantenha `OptLevel.NO_OPT`, `setMemoryPatternOptimization(false)` e `setCPUArenaAllocator(false)`. Otimizações de grafo `ALL_OPT` e a arena de memória causam crash nativo / pico de RAM em aparelhos Android com 6 GB de RAM ou menos.
- **DirectByteBuffer & JNI:**
  - Mantenha referência forte ao `ByteBuffer` direto durante toda a execução de `session.run(...)` para impedir coleta prematura pelo GC.
  - Retorne `FloatArray` (primitivo) pelo `MethodChannel` em vez de `List<Double>` (evita boxing de 10.861 objetos).
  - Não envie `imageBytes` multi-megabyte pelo `MethodChannel`; decodifique diretamente a partir de `imagePath` no Kotlin usando `BitmapFactory` com `inSampleSize`.
- **Memória:** Mantenha `android:largeHeap="true"` em `AndroidManifest.xml`.

### 4.2. Armazenamento de Imagens, Mover/Copiar e Pastas de Collections
- **Estrutura no disco:**
  - Imagens soltas ficam em `booru/files/<arquivo>`.
  - Imagens pertencentes a uma Collection ficam em `booru/files/<pasta_da_collection>/<arquivo>`.
  - Em `repoinfo.json`, `file["filename"]` armazena o caminho **relativo a `booru/files/`** com separador `/` (ex: `"MinhaPasta/img.png"` ou `"img.png"`).
  - Sempre use `readable.dart` / `writable.dart` (`p.joinAll` dividindo por `/`) ao resolver ou mover arquivos.
- **Modo Mover (`file_import_mode = "move"`):**
  - Nunca apague o arquivo original antes de confirmar `copiedFile.exists() && copiedFile.length() > 0`.
  - No Android, **nunca** use `FilePicker.platform.pickFiles` diretamente para selecionar imagens: o `file_picker` copia o arquivo selecionado para `/data/user/0/.../cache/file_picker/` e retorna o caminho do cache temporário (fazendo com que o modo *Mover* apague apenas a cópia do cache e mantenha a imagem original intacta no armazenamento do celular). Sempre use `pickMediaFilesWithRealPaths()` e `pickDirectoryWithRealPath()` (`lib/utils/platform_tools.dart` + canal nativo `com.auser.localbooru/storage` em `MainActivity.kt`), que resolvem o caminho real em `/storage/...` via `DocumentsContract`, `MediaStore` e `/proc/self/fd` (`Os.readlink`) e preservam a `Uri` SAF com permissão de escrita.
  - Sempre remova o arquivo de origem usando `deleteSourceFileAfterMove` (`lib/utils/platform_tools.dart`), que limpa o `imageCache` do Flutter, executa deleção via `File.delete()`, `DocumentsContract.deleteDocument` e `MediaStore` (`ContentResolver.delete`), e aciona `MediaScannerConnection.scanFile` para atualizar a Galeria do Android imediatamente.
  - Quando uma imagem for comprimida antes de salvar, `PresetImage.originalImage` guarda o arquivo de origem para que ambos (temporário comprimido e original) sejam limpos corretamente no modo Mover.
  - Não apague arquivos que já estejam dentro de `booru/files/` ao apenas editar metadados (`replaceID != null`), exceto ao movê-los entre subpastas de collections.

### 4.3. Auto-Tagging (`autotag.dart` e `shell.dart`)
- **UI em lote:** Nunca use `IndexedStack` com dezenas de `ImageManagerForm` simultâneos (causa OOM/freeze em pastas grandes). Use renderização sob demanda da página atual.
- **Fallback e `"tagme"`:** Só atribua `"tagme"` se todas as listas de tags estiverem vazias após o pós-processamento. Se o `filterThreshold` não retornar nenhuma tag, aplique fallback para as top tags com score `>= 0.10`/`0.15`.
- **Modos de execução:** `"auto"` (tenta offline se baixado, senão online), `"offline"` (exige modelo baixado), `"online"` (HuggingFace `smilingwolf-wd-tagger.hf.space` com fallback para `autotagger.donmai.us`).

### 4.4. Thumbnails (`compressor.dart` e `image_grid_display.dart`)
- `FcNativeVideoThumbnail` **não suporta GIFs** no Android.
- `createThumbnail` deve tratar `image/gif` via `compressImage` com fallback para o próprio arquivo original (`input`), e `ImageGrid` deve sempre tratar `snapshot.hasError` no `FutureBuilder` para nunca travar em `CircularProgressIndicator` infinito.

### 4.5. Navegação e Botão Voltar no Android (`main.dart` e `routing.dart`)
- O app usa `ShellRoute`s aninhados no `GoRouter` (`LockScreen` -> `MobileHousing`/`DesktopHousing` -> `ShortcutHandler`).
- `MaterialApp.router` **deve** usar `SafeBackButtonDispatcher(router)` (em `lib/main.dart`) em vez de `routerConfig` padrão, garantindo que se `super.didPopRoute()` retornar `false` nos `ShellRoute`s, `goRouter.canPop()` ainda execute `goRouter.pop()` antes de deixar o Android fechar o app.
- Ao adicionar imports/símbolos em `routing.dart` (como `PresetImage`), lembre-se de importar `package:localbooru/api/preset/index.dart`.
