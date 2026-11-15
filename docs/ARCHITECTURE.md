# Arquitetura do Projeto

Este documento descreve a organização interna do código, o modelo de dados local e os fluxos principais do **LocalBooru** (fork Android/Desktop).

---

## 1. Visão Geral em Camadas

```text
┌──────────────────────────────────────────────────────────┐
│                     UI (lib/views/)                      │
│  HomePage • GalleryViewer • GallerySwipeView • Settings  │
│  ImageManagerShell • ImageManagerForm • CollectionList   │
└───────────────────────────┬──────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────┐
│                 Camada de Domínio (lib/api/)             │
│  Booru (readable/writable) • PresetImage/Collection      │
│  WaifuTagger / AutoTag • Search & Metatags               │
└──────────────┬───────────────────────────┬───────────────┘
               │                           │
┌──────────────▼──────────────┐ ┌──────────▼───────────────┐
│   Armazenamento Local       │ │  Canal Nativo Android    │
│   • repoinfo.json           │ │  MainActivity.kt         │
│   • files/ (+ subpastas)    │ │  com.auser.localbooru/   │
│   • thumbnails/             │ │  waifutagger (ONNX 1.20) │
└─────────────────────────────┘ └──────────────────────────┘
```

---

## 2. Armazenamento Local (`repoinfo.json` e `files/`)

Um booru é uma pasta escolhida pelo usuário contendo:
- `repoinfo.json`: metadados de todas as imagens (`files`), coleções (`collections`) e categorias de tags conhecidas (`specificTags`: `artist`, `character`, `copyright`, `species`).
- `files/`: armazenamento dos arquivos originais.
  - Imagens sem coleção ficam na raiz `files/<arquivo>`.
  - Imagens em uma Collection ficam em `files/<pasta_da_collection>/<arquivo>`.
  - O campo `filename` em `repoinfo.json` guarda o caminho relativo a `files/` (ex.: `"minha_pasta/arte.png"`).
- `thumbnails/`: miniaturas JPEG em cache geradas por `lib/utils/compressor.dart` usando o padrão `<id>_<nome_sem_extensao>.jpg` (com compatibilidade legada `<nome>.jpg`).

### Regras de Copiar vs. Mover e Collections
- **Copiar vs. Mover (`file_import_mode`):** Configurável em *Settings > Behavior* e diretamente na tela de importação. No modo **Mover**, o arquivo é copiado para o destino, validado (`exists() && length() > 0`) e o original é removido.
- **Sincronização Pasta ↔ Collection (`lib/api/writable.dart`):**
  - Criar uma Collection cria a pasta `files/<nome_sanitizado>/`.
  - Importar uma pasta para tagging pré-marca a opção de preservar a pasta como Collection com o nome da pasta de origem (e remove a pasta de origem se ela ficar vazia no modo *Mover*).
  - Adicionar imagens existentes a uma Collection move os arquivos físicos para a pasta da Collection; remover da Collection ou excluir a Collection devolve os arquivos para a raiz `files/`.

---

## 3. Sistema de Auto-Tagging (`lib/api/tags/autotag.dart`)

### Modelos disponíveis
1. **`wd-convnext-v3-mobile`** (~95 MB) — *Smashinfries/wd-convnext-tagger-v3-onnx-mobile* (INT8/UINT8, recomendado para celulares).
2. **`wd-swinv2-v3-mobile`** (~115 MB) — *Smashinfries/wd-swinv2-tagger-v3-onnx-mobile* (INT8/UINT8, maior precisão).
3. **`wd-vit-v3`** (~360 MB) — *SmilingWolf/wd-vit-tagger-v3* (FP32 completo).

Os modelos baixados são salvos em `getApplicationSupportDirectory()/waifutagger_models/`.

### Fluxo de Execução (`autoTagDetailed`)
1. **Offline (Android, quando `autotag_mode != "online"`):**
   - Verifica se `.onnx` (> 50 MB) e arquivo de vocabulário (`.json` ou `.csv`) existem.
   - Chama o `MethodChannel("com.auser.localbooru/waifutagger")` com `runInference(modelPath, imagePath)`.
   - Em `MainActivity.kt`, a imagem é decodificada com `BitmapFactory` (subsampling para economizar RAM), redimensionada com padding branco para `448x448`, convertida para tensor `UINT8 RGB` (modelos `-mobile`) ou `FLOAT32 BGR` (modelos padrão) e executada em `OrtSession` com `OptLevel.NO_OPT` e arena de CPU desabilitada.
   - Retorna `FloatArray` com as probabilidades para o Dart mapear nas categorias (`generic`, `artist`, `character`, `copyright`, `species` e `rating`).
2. **Online Fallback (`autotag_mode != "offline"` ou se falhar):**
   - Tenta a API Gradio do HuggingFace Space `smilingwolf-wd-tagger.hf.space`.
   - Em último caso, usa `https://autotagger.donmai.us/evaluate`.

---

## 4. Navegação e Galeria

- **Rotas (`lib/routing.dart`):** Gerenciadas pelo `GoRouter`.
- **Botão Voltar (`lib/main.dart`):** `SafeBackButtonDispatcher` estende `RootBackButtonDispatcher` para garantir que eventos de voltar no Android naveguem pela pilha do `GoRouter` (`goRouter.pop()`) mesmo com múltiplos `ShellRoute`s aninhados.
- **Swipe Gallery (`image_view.dart` & `zoomed_view.dart`):** Recebe `galleryIds` via `state.extra` (ou carrega todos os IDs do booru) e renderiza um `PageView.builder` permitindo deslizar entre imagens adjacentes.
