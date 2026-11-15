<p align="center"><img src="assets/promotional/banner + screenshot.png"/></p>

<p align="center">
    Your personal booru collection
</p>
<p align="center">
    This is a cross platform local booru collection that exclusively works on your local storage, without selfhosting.
</p>
<p align="center">
    <img src="https://img.shields.io/github/issues/resucutie/localbooru?style=for-the-badge&color=673AB7"/>
    <img src="https://img.shields.io/github/issues-pr/resucutie/localbooru?style=for-the-badge&color=673AB7"/>
</p>
<p align="center">
    <a href="https://en.liberapay.com/resucutie"><img src="https://img.shields.io/liberapay/receives/resucutie?style=for-the-badge&logo=liberapay"/></a>
    <a href="https://github.com/sponsors/resucutie"><img src="https://img.shields.io/github/sponsors/resucutie?style=for-the-badge&logo=githubsponsors&color=EA4AAA"/></a>
    <a href="https://discord.gg/D5kdKePY52"><img src="https://img.shields.io/badge/check%20our%20discord%20server-673AB7?style=for-the-badge"/></a>
</p>


## Targetted platforms
- Windows
- Android
- Linux
  - [AUR](https://aur.archlinux.org/packages/localbooru) (`localbooru`) ![AUR](https://img.shields.io/aur/version/localbooru)
  - [NUR](https://github.com/ixhbinphoenix/nur-packages) (`nur.repos.ixhbinphoenix.localbooru-bin`)

### Planned platforms
- macOS
- iOS (Sideloading)

## Install
### Windows
You will need the [Microsoft Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe) installed for using this program.  
After doing that, go and download the setup wizard file over at [Releases](https://github.com/resucutie/localbooru/releases/latest)

<!-- ### macOS
Download `localbooru-macos.zip` over at [Releases](https://github.com/resucutie/localbooru/releases/latest), extract its file contents and grab the LocalBooru.app file -->

### Linux
There are prebuilt .deb and .rpm packages over at [Releases](https://github.com/resucutie/localbooru/releases/latest), but you can download the binaries if you want. Flatpak support is planned as of writing  

The package is avaiable on the [AUR](https://aur.archlinux.org/packages/localbooru) and on the NUR (`nur.repos.ixhbinphoenix.localbooru-bin`)


### Android
Download `localbooru-android.apk` over at [Releases](https://github.com/resucutie/localbooru/releases/latest) and install it by opening the file

You can use [Obtanium](https://github.com/ImranR98/Obtainium) if you want an update manager


## FAQ
You can check the [FAQ](https://github.com/resucutie/localbooru/wiki/FAQ) over here

## Documentation (Fork Features & Development)
- [AGENTS.md](AGENTS.md) — Guide for AI coding agents and contributors (conventions, native ONNX rules, known pitfalls).
- [Architecture](docs/ARCHITECTURE.md) — Internal architecture, `repoinfo.json` + collection folder storage, WaifuTagger ONNX pipeline, and navigation.
- [Development & Build](docs/DEVELOPMENT.md) — Local setup, Android APK builds, GitHub Actions CI, and hardware requirements for local models.

### Key additions in this fork
- **WaifuTagger / WD Tagger v3:** Local offline ONNX inference on Android (`wd-convnext-v3-mobile`, `wd-swinv2-v3-mobile`, `wd-vit-v3`) with online fallback.
- **Batch Folder Tagging & Collections:** Import an entire folder, auto-tag all images in batch, choose between **Copy** or **Move**, and preserve the folder as a Collection inside `booru/files/<collection>/`.
- **Swipe Gallery:** Swipe horizontally between images in both detail view and zoom view.
