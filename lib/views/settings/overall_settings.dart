import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:localbooru/api/tags/index.dart';
import 'package:localbooru/components/counter.dart';
import 'package:localbooru/components/headers.dart';
import 'package:localbooru/components/dialogs/radio_dialogs.dart';
import 'package:localbooru/utils/constants.dart';
import 'package:localbooru/utils/listeners.dart';
import 'package:localbooru/utils/platform_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/error_codes.dart' as auth_error;

class OverallSettings extends StatefulWidget {
    const OverallSettings({super.key, required this.prefs});

    final SharedPreferences prefs;

    @override
    State<OverallSettings> createState() => _OverallSettingsState();
}

class _OverallSettingsState extends State<OverallSettings> {
    final _pageSizeValidator = GlobalKey<FormState>();
    final _pageSizeController = TextEditingController();
    final LocalAuthentication auth = LocalAuthentication();

    late double _gridSizeSliderValue;
    late double _autotagAccuracy;
    late double _thumbnailQuality;
    late bool _monetTheme;
    late bool _update;
    late bool _gifVideo;
    late bool _authLock;
    late bool _customFrame;
    late String _theme;
    late String _counter;
    late String _autotagModel;
    late String _autotagMode;
    bool _isModelDownloaded = false;
    bool _isDownloadingModel = false;
    double _downloadProgress = 0.0;
    String _downloadStatus = "";

    bool isAuthLockOptionEnabled = false;

    bool isSettingModified(String setting) {
        return widget.prefs.get(setting) != null && widget.prefs.get(setting) != settingsDefaults[setting];
    }

    void resetProp(String setting, {Function(dynamic)? modifier}) {
        widget.prefs.remove(setting);
        setState(() {
            if(modifier != null) modifier(settingsDefaults[setting]);
        });
    }

    Future<void> _checkModelDownloaded() async {
        final model = getWaifuTaggerModelById(_autotagModel);
        final downloaded = await isWaifuTaggerModelDownloaded(model);
        if (mounted) {
            setState(() => _isModelDownloaded = downloaded);
        }
    }

    @override
    void initState() {
        super.initState();
        _gridSizeSliderValue = (widget.prefs.getInt("grid_size") ?? settingsDefaults["grid_size"]).toDouble();
        _autotagAccuracy = widget.prefs.getDouble("autotag_accuracy") ?? settingsDefaults["autotag_accuracy"];
        _autotagModel = widget.prefs.getString("autotag_model") ?? settingsDefaults["autotag_model"];
        _autotagMode = widget.prefs.getString("autotag_mode") ?? settingsDefaults["autotag_mode"];
        _thumbnailQuality = widget.prefs.getDouble("thumbnail_quality") ?? settingsDefaults["thumbnail_quality"];
        _pageSizeController.text = (widget.prefs.getInt("page_size") ?? settingsDefaults["page_size"]).toString();
        _monetTheme = widget.prefs.getBool("monet") ?? settingsDefaults["monet"];
        _update = widget.prefs.getBool("update") ?? settingsDefaults["update"];
        _gifVideo = widget.prefs.getBool("gif_video") ?? settingsDefaults["gif_video"];
        _theme = widget.prefs.getString("theme") ?? settingsDefaults["theme"];
        _counter = widget.prefs.getString("counter") ?? settingsDefaults["counter"];
        _authLock = widget.prefs.getBool("auth_lock") ?? settingsDefaults["auth_lock"];
        _customFrame = widget.prefs.getBool("custom_frame") ?? settingsDefaults["custom_frame"];

        _checkModelDownloaded();

        LocalAuthentication().isDeviceSupported().then((value) => setState(() {
            isAuthLockOptionEnabled = value && isMobile();
        }));
    }

    Future<void> onChangeTheme() async {
        final choosenTheme = await showDialog<String>(
            context: context,
            builder: (_) => ThemeChangerDialog(theme: widget.prefs.getString("theme") ?? settingsDefaults["theme"])
        );
        if(choosenTheme == null) return;
        widget.prefs.setString("theme", choosenTheme);
        themeListener.update();
        setState(() => _theme = choosenTheme);
    }

    Future<void> onChangeCounter() async {
        final choosenCounter = await showDialog<String>(
            context: context,
            builder: (_) => CounterChangerDialog(counter: widget.prefs.getString("counter") ?? settingsDefaults["counter"])
        );
        if(choosenCounter == null) return;
        widget.prefs.setString("counter", choosenCounter);
        setState(() => _counter = choosenCounter);
        counterListener.update();
    }

    @override
    Widget build(BuildContext context) {
        return ListView(
            children: [
                const SmallHeader("Browsing"),
                SliderListTile(
                    title: Row(
                        children: [
                            const Text("Grid size"),
                            if(isSettingModified("grid_size")) IconButton(
                                onPressed: () => resetProp("grid_size", modifier: (v) => _gridSizeSliderValue = v.toDouble()),
                                icon: const Icon(Icons.restart_alt)
                            )
                        ],
                    ),
                    leading: const Icon(Icons.grid_3x3),
                    subtitle: const Text("Set how many columns should be displayed dynamically"),
                    extremeTips: const [Text("Less elements"), Text("More elements")],
                    value: _gridSizeSliderValue,
                    min: 1,
                    max: 10,
                    divisions: 9,
                    onChanged: (value) async {
                        setState(() => _gridSizeSliderValue = value);
                        widget.prefs.setInt("grid_size", value.ceil());
                    },
                ),
                ListTile(
                    title: Row(
                        children: [
                            const Text("Page size"),
                            if(isSettingModified("page_size")) IconButton(
                                onPressed: () => resetProp("page_size", modifier: (v) => _pageSizeController.text = v.toString()),
                                icon: const Icon(Icons.restart_alt)
                            )
                        ],
                    ),
                    leading: const Icon(Icons.visibility),
                    subtitle: Wrap(
                        children: [
                            const Text("How many images per page should be displayed"),
                            Form(
                                key: _pageSizeValidator,
                                child: TextFormField(
                                    controller: _pageSizeController,
                                    validator: (value) {
                                        if(value == null || value.isEmpty) return "Cannot be empty";
                                        if(int.parse(value) > 100) return "Isn't it too big?";
                                        return null;
                                    },
                                    keyboardType: const TextInputType.numberWithOptions(decimal: false),
                                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9]+')),],
                                    onChanged: (value) {
                                        _pageSizeValidator.currentState!.validate();
                                        if(value.isEmpty || int.parse(value) > 100) return;
                                        setState(() {});
                                        widget.prefs.setInt("page_size", int.parse(value));
                                    },
                                ),
                            )
                        ],
                    )
                ),
                SliderListTile(
                    title: Row(
                        children: [
                            const Text("Thumbnail quality"),
                            if(isSettingModified("thumbnail_quality")) IconButton(
                                onPressed: () => resetProp("thumbnail_quality", modifier: (v) => _thumbnailQuality = v),
                                icon: const Icon(Icons.restart_alt)
                            )
                        ],
                    ),
                    leading: const Icon(Icons.image_aspect_ratio),
                    subtitle: const Text("Set how high quality should the thumbnails be on the browse screen. The less, the less ram will be used, but the preview will be lower quality"),
                    extremeTips: const [Text("0.5x displayed"), Text("3x displayed")],
                    value: _thumbnailQuality,
                    min: 0.5,
                    max: 3,
                    divisions: 5,
                    label: "$_thumbnailQuality",
                    onChanged: (value) async {
                        setState(() => _thumbnailQuality = value);
                        widget.prefs.setDouble("thumbnail_quality", value);
                    },
                ),
                
                const SmallHeader("Tags (WaifuTagger / WD14)"),
                ListTile(
                    leading: const Icon(Icons.psychology),
                    title: const Text("Tagger Model (WaifuTagger)"),
                    subtitle: Text("${getWaifuTaggerModelById(_autotagModel).name}\n${getWaifuTaggerModelById(_autotagModel).description}"),
                    isThreeLine: true,
                    onTap: () async {
                        final selected = await showDialog<String>(
                            context: context,
                            builder: (ctx) => SimpleDialog(
                                title: const Text("Select WaifuTagger Model"),
                                children: availableWaifuTaggerModels.map((m) => RadioListTile<String>(
                                    value: m.id,
                                    groupValue: _autotagModel,
                                    title: Text(m.name),
                                    subtitle: Text(m.description),
                                    onChanged: (val) => Navigator.of(ctx).pop(val),
                                )).toList(),
                            ),
                        );
                        if (selected != null) {
                            await widget.prefs.setString("autotag_model", selected);
                            setState(() => _autotagModel = selected);
                            await _checkModelDownloaded();
                        }
                    },
                ),
                ListTile(
                    leading: const Icon(Icons.cloud_sync),
                    title: const Text("Execution Mode"),
                    subtitle: Text(switch (_autotagMode) {
                        "offline" => "Offline only (ONNX on Android device)",
                        "online" => "Online only (HuggingFace WD-Tagger API)",
                        _ => "Auto (Offline if downloaded, Online fallback)",
                    }),
                    onTap: () async {
                        final selected = await showDialog<String>(
                            context: context,
                            builder: (ctx) => SimpleDialog(
                                title: const Text("Tagger Execution Mode"),
                                children: [
                                    RadioListTile<String>(
                                        value: "auto",
                                        groupValue: _autotagMode,
                                        title: const Text("Automatic (Recommended)"),
                                        subtitle: const Text("Uses offline ONNX model if downloaded, otherwise falls back to online API"),
                                        onChanged: (val) => Navigator.of(ctx).pop(val),
                                    ),
                                    RadioListTile<String>(
                                        value: "offline",
                                        groupValue: _autotagMode,
                                        title: const Text("Offline Only (Local ONNX)"),
                                        subtitle: const Text("Runs 100% offline on Android using downloaded WaifuTagger ONNX model"),
                                        onChanged: (val) => Navigator.of(ctx).pop(val),
                                    ),
                                    RadioListTile<String>(
                                        value: "online",
                                        groupValue: _autotagMode,
                                        title: const Text("Online Only"),
                                        subtitle: const Text("Always uses remote WD14 Tagger API without local storage"),
                                        onChanged: (val) => Navigator.of(ctx).pop(val),
                                    ),
                                ],
                            ),
                        );
                        if (selected != null) {
                            await widget.prefs.setString("autotag_mode", selected);
                            setState(() => _autotagMode = selected);
                        }
                    },
                ),
                ListTile(
                    leading: Icon(
                        _isModelDownloaded ? Icons.download_done : Icons.download,
                        color: _isModelDownloaded ? Colors.green : null,
                    ),
                    title: Text(_isModelDownloaded
                        ? "Offline Model Downloaded (${getWaifuTaggerModelById(_autotagModel).sizeHint})"
                        : "Download Model for Offline Use (${getWaifuTaggerModelById(_autotagModel).sizeHint})"),
                    subtitle: _isDownloadingModel
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                const SizedBox(height: 4),
                                Text(_downloadStatus),
                                const SizedBox(height: 4),
                                LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null),
                            ],
                        )
                        : Text(_isModelDownloaded
                            ? "Ready for offline tagging on Android. Tap to delete or re-download."
                            : "Download ONNX model & tags vocabulary from HuggingFace"),
                    trailing: _isDownloadingModel
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : (_isModelDownloaded
                            ? IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: "Delete offline model",
                                onPressed: () async {
                                    await deleteWaifuTaggerModel(getWaifuTaggerModelById(_autotagModel));
                                    await _checkModelDownloaded();
                                    if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text("Offline model removed.")),
                                        );
                                    }
                                },
                            )
                            : null),
                    onTap: _isDownloadingModel ? null : () async {
                        final model = getWaifuTaggerModelById(_autotagModel);
                        setState(() {
                            _isDownloadingModel = true;
                            _downloadProgress = 0.0;
                            _downloadStatus = "Iniciando download...";
                        });
                        try {
                            await downloadWaifuTaggerModel(
                                model,
                                onProgress: (progress, status) {
                                    if (mounted) {
                                        setState(() {
                                            _downloadProgress = progress;
                                            _downloadStatus = status;
                                        });
                                    }
                                },
                            );
                            await _checkModelDownloaded();
                            if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("${model.name} baixado com sucesso!")),
                                );
                            }
                        } catch (e) {
                            if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Erro ao baixar modelo: $e")),
                                );
                            }
                        } finally {
                            if (mounted) {
                                setState(() => _isDownloadingModel = false);
                            }
                        }
                    },
                ),
                SliderListTile(
                    title: Row(
                        children: [
                            const Text("Autotag accuracy"),
                            if(isSettingModified("autotag_accuracy")) IconButton(
                                onPressed: () => resetProp("autotag_accuracy", modifier: (v) => _autotagAccuracy = v),
                                icon: const Icon(Icons.restart_alt)
                            )
                        ],
                    ),
                    leading: const Icon(CupertinoIcons.sparkles),
                    subtitle: const Text("How accurate should be the results of the autotagger"),
                    extremeTips: const [Text("Less accurate"), Text("More accurate")],
                    //TODO: Make this slider go in an exponential curve
                    value: _autotagAccuracy,
                    min: 0,
                    max: 1,
                    label: "${(_autotagAccuracy*100).round()}%",
                    onChanged: (value) async {
                        setState(() => _autotagAccuracy = value);
                        widget.prefs.setDouble("autotag_accuracy", value);
                    },
                ),
                
                const SmallHeader("Appearence"),
                ListTile(
                    title: const Text("Theme"),
                    subtitle: Text(_theme.replaceFirstMapped(_theme[0], (match) => _theme[0].toUpperCase())),
                    leading: const Icon(Icons.dark_mode),
                    onTap: onChangeTheme,
                ),
                SwitchListTile(
                    title: const Text("Dynamic colors"),
                    secondary: const Icon(Icons.palette),
                    subtitle: const Text("For desktop devices: It will apply the current accent color as the dynamic colors"),
                    value: _monetTheme,
                    onChanged: (value) {
                        widget.prefs.setBool("monet", value);
                        themeListener.update();
                        setState(() => _monetTheme = value);
                    }
                ),
                if(hasWindowFrameNavigation()) SwitchListTile(
                    title: const Text("Custom window frame"),
                    secondary: const Icon(Icons.web_asset),
                    subtitle: const Text("Show a custom window frame"),
                    value: _customFrame,
                    onChanged: (value) {
                        widget.prefs.setBool("custom_frame", value);
                        setState(() => _customFrame = value);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Restart the app to take effect")));
                    }
                ),
                ListTile(
                    title: const Text("Counter"),
                    subtitle: Text(_counter),
                    leading: StyleCounter(number: Random().nextInt(10), height: 24, display: _counter,),
                    onTap: onChangeCounter,
                ),

                const SmallHeader("Behavior"),
                SwitchListTile(
                    title: const Text("Display GIFs as videos"),
                    secondary: const Icon(Icons.gif),
                    subtitle: const Text("It will add video controllers to GIFs"),
                    value: _gifVideo,
                    onChanged: (value) {
                        widget.prefs.setBool("gif_video", value);
                        setState(() => _gifVideo = value);
                    }
                ),
                if(isAuthLockOptionEnabled) SwitchListTile(
                    title: const Text("Enable biometric hideout"),
                    secondary: const Icon(Icons.fingerprint),
                    subtitle: const Text("Hide content under a lock screen whenever the app is put in background"),
                    value: _authLock,
                    onChanged: (value) async {
                        if(value) {
                            try {
                                final didAuthenticate = await auth.authenticate(
                                    localizedReason: "Biometric check before enabling"
                                );
                                if(didAuthenticate) widget.prefs.setBool("auth_lock", true);
                            } on PlatformException catch (error) {
                                final String message = switch(error.code) {
                                    auth_error.otherOperatingSystem => "This system shouldn't have any support for authentication lock",
                                    auth_error.notAvailable || auth_error.notEnrolled || auth_error.passcodeNotSet => "You don't have any auth system avaiable",
                                    auth_error.lockedOut => "You tried too many times. Please wait till your system allows",
                                    _ => error.message!
                                };
                                if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
                            }
                        } else {
                            widget.prefs.setBool("auth_lock", false);
                        }
                        setState(() => _authLock = widget.prefs.getBool("auth_lock")!);
                    }
                ),
                const SmallHeader("Other"),
                SwitchListTile(
                    title: const Text("Prompt for updates"),
                    secondary: const Icon(Icons.cached),
                    subtitle: const Text("If the program it outdated, it'll prompt for an update"),
                    value: _update,
                    onChanged: (value) {
                        widget.prefs.setBool("update", value);
                        setState(() => _update = value);
                    }
                ),
            ],
        );
    }
}

class SliderListTile extends StatelessWidget {
    const SliderListTile({super.key, this.title, this.leading, required this.value, this.min = 0, this.max = 1, this.label, this.onChanged, this.subtitle, this.extremeTips, this.divisions});
    
    final Widget? title;
    final Widget? subtitle;
    final List<Widget>? extremeTips;
    final Widget? leading;
    final double value;
    final double min;
    final double max;
    final int? divisions;
    final String? label;
    final Function(double)? onChanged;


    @override
    Widget build(BuildContext context) {
        return ListTile(
            title: title,
            leading: leading,
            subtitle: Wrap(
                children: [
                    if(subtitle != null) subtitle!,
                    if(extremeTips != null) Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: extremeTips!
                    ),
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12.0),
                        child: SliderTheme(
                            data: SliderThemeData(overlayShape: SliderComponentShape.noOverlay, showValueIndicator: ShowValueIndicator.always),
                            child: Slider(
                                value: value,
                                min: min,
                                max: max,
                                label: label,
                                divisions: divisions,
                                onChanged: onChanged,
                            ),
                        ),
                    )
                ],
            )
        );
    }
}