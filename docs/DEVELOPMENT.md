# Guia de Desenvolvimento e Build

Este guia explica como configurar o ambiente, compilar o aplicativo (inclusive via GitHub Actions) e entender os requisitos dos modelos locais.

---

## 1. Pré-requisitos Locais

- **Flutter SDK:** `3.27.3` (stable)
- **Java JDK:** 17 (para Android)
- **Android SDK:** `compileSdkVersion 34`, `minSdkVersion 23`
- **Desktop (opcional):**
  - **Linux:** `clang`, `ninja-build`, `libgtk-3-dev`, `libmpv-dev`, `mpv`
  - **Windows:** Visual Studio com workload *Desktop development with C++*

---

## 2. Executando e Compilando

### Instalar dependências
```bash
flutter pub get
```

### Análise estática e testes
```bash
flutter analyze
flutter test
```

### Gerar APK Android (Release)
```bash
flutter build apk --release
```
O arquivo gerado ficará em:
`build/app/outputs/apk/release/app-release.apk`

> **Nota sobre R8/ProGuard:** O arquivo `android/app/proguard-rules.pro` é aplicado automaticamente no build `--release` via `android/app/build.gradle` para preservar as classes JNI do `onnxruntime-android`.

---

## 3. Build Automático no GitHub Actions

O workflow [`.github/workflows/flutter-deploy.yaml`](../.github/workflows/flutter-deploy.yaml) é executado em todo `push` ou manualmente via **Actions > Flutter CI > Run workflow**:

1. Acesse a aba **Actions** do repositório no GitHub.
2. Abra a execução mais recente do workflow **Flutter CI**.
3. Na seção **Artifacts**, baixe:
   - `localbooru-android-apk` (APK pronto para instalar no celular, se não houver secrets de keystore configurados) ou `localbooru-android` (APK assinado com sua keystore).
4. Transfira o `.apk` para o celular e instale (habilitando instalação de fontes desconhecidas).

---

## 4. Requisitos Mínimos de Hardware (Auto-Tagging Local no Android)

| Modelo | Tamanho em Disco | RAM Mínima Recomendada | Observações |
| :--- | :--- | :--- | :--- |
| **WD ConvNeXt v3 Mobile (INT8)** | ~95 MB | 4 GB (6 GB+ recomendado) | Mais rápido e leve para uso local no celular. |
| **WD SwinV2 v3 Mobile (INT8)** | ~115 MB | 6 GB+ | Maior precisão em ilustrações, porém mais pesado em CPU/RAM. |
| **WD ViT v3 (FP32)** | ~360 MB | 8 GB+ | Modelo completo em ponto flutuante; recomenda-se usar em aparelhos mais potentes ou no modo Online. |

Caso seu dispositivo tenha pouca memória ou queira economizar bateria/armazenamento, alterne para o modo **Online Only** ou **Automatic** em *Settings > Execution Mode*.
