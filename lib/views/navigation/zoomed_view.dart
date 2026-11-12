import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localbooru/api/index.dart';
import 'package:localbooru/components/context_menu.dart';
import 'package:localbooru/utils/platform_tools.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:localbooru/components/window_frame.dart';
import 'package:window_manager/window_manager.dart';


class ImageViewZoom extends StatefulWidget {
    const ImageViewZoom(this.image, {super.key, this.galleryIds});

    final BooruImage image;
    final List<ImageID>? galleryIds;
  
    @override
    State<ImageViewZoom> createState() => _ImageViewZoomState();
}

class _ImageViewZoomState extends State<ImageViewZoom> {
    PhotoViewController controller = PhotoViewController();
    PageController? _pageController;
    List<ImageID> _ids = [];
    int _currentIndex = 0;
    BooruImage? _currentImage;
    final Map<ImageID, BooruImage> _imageCache = {};

    @override
    void initState() {
        super.initState();
        _currentImage = widget.image;
        _imageCache[widget.image.id] = widget.image;
        _initGallery();
    }

    Future<void> _initGallery() async {
        final booru = await getCurrentBooru();
        List<ImageID> ids = widget.galleryIds != null && widget.galleryIds!.isNotEmpty
            ? List<ImageID>.from(widget.galleryIds!)
            : [];

        if (ids.isEmpty) {
            final raw = await booru.getRawInfo();
            final List files = raw["files"] ?? [];
            ids = files.map((f) => f["id"].toString()).toList().reversed.toList();
        }

        int initialIdx = ids.indexOf(widget.image.id);
        if (initialIdx < 0) {
            ids.insert(0, widget.image.id);
            initialIdx = 0;
        }

        if (mounted) {
            setState(() {
                _ids = ids;
                _currentIndex = initialIdx;
                _pageController = PageController(initialPage: initialIdx);
            });
        }
        _preloadNeighbors(initialIdx);
    }

    Future<void> _preloadNeighbors(int index) async {
        final booru = await getCurrentBooru();
        for (final offset in [-1, 0, 1]) {
            final idx = index + offset;
            if (idx >= 0 && idx < _ids.length) {
                final id = _ids[idx];
                if (!_imageCache.containsKey(id)) {
                    final img = await booru.getImage(id);
                    if (img != null && mounted) {
                        setState(() {
                            _imageCache[id] = img;
                            if (idx == _currentIndex) _currentImage = img;
                        });
                    }
                }
            }
        }
    }

    @override
    void dispose() {
        controller.dispose();
        _pageController?.dispose();
        super.dispose();
    }

    void zoom(num scaleFactor) {
        controller.scale = (controller.scale ?? 1) * scaleFactor;
        controller.position = Offset(controller.position.dx * scaleFactor, controller.position.dy * scaleFactor);
    }

    @override
    Widget build(BuildContext context) {
        final activeImage = _currentImage ?? widget.image;
        return OrientationBuilder(
            builder: (context, orientation) {
                final AppBar appBar = AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    title: Text(
                        _ids.length > 1
                            ? "${activeImage.filename} (${_currentIndex + 1}/${_ids.length})"
                            : activeImage.filename,
                    ),
                    actions: [
                        if(orientation == Orientation.landscape) ...[
                            IconButton(
                                icon: const Icon(Icons.zoom_in),
                                onPressed: () => zoom(1.5),
                            ),
                            IconButton(
                                icon: const Icon(Icons.zoom_out),
                                onPressed: () => zoom(0.7),
                            )
                        ],
                        PopupMenuButton(
                            itemBuilder: (context) => imageShareItems(activeImage),
                        ),
                    ],
                );
                return Theme(
                    data: ThemeData.dark(),
                    child: Scaffold(
                        extendBodyBehindAppBar: true,
                        backgroundColor: Colors.transparent,
                        appBar: isDesktop() ? PreferredSize(
                            preferredSize: Size.fromHeight(32 + appBar.preferredSize.height),
                            child: Container(
                                color: const Color.fromARGB(150, 0, 0, 0),
                                child: Wrap(
                                    direction: Axis.horizontal,
                                    children: [
                                        const WindowFrameAppBar(title: null),
                                        GestureDetector(
                                            onTapDown: (details) => windowManager.startDragging(),
                                            child: appBar,
                                        )
                                    ],
                                ),
                            ),
                        ) : appBar,
                        body: Listener(
                            onPointerSignal:(event) {
                                if(event is PointerScrollEvent) {
                                    double scrollBy = .15;
                                    if(!event.scrollDelta.dy.isNegative) {
                                        if((controller.scale ?? 1) <= .1) return;
                                        scrollBy = -scrollBy;
                                    }
                                    zoom(1 + scrollBy);
                                }
                            },
                            child: GestureDetector(
                                onVerticalDragEnd: (details) {
                                    if(details.velocity.pixelsPerSecond.dy.abs() > 300) context.pop();
                                },
                                child: _pageController == null || _ids.isEmpty
                                    ? PhotoViewGestureDetectorScope(
                                        axis: Axis.vertical,
                                        child: PhotoView(
                                            imageProvider: FileImage(activeImage.getImage()),
                                            heroAttributes: PhotoViewHeroAttributes(tag: "detailed_${activeImage.id}"),
                                            minScale: .1,
                                            controller: controller,
                                        ),
                                    )
                                    : PhotoViewGallery.builder(
                                        pageController: _pageController,
                                        itemCount: _ids.length,
                                        onPageChanged: (index) {
                                            setState(() {
                                                _currentIndex = index;
                                                final id = _ids[index];
                                                if (_imageCache.containsKey(id)) {
                                                    _currentImage = _imageCache[id];
                                                }
                                            });
                                            _preloadNeighbors(index);
                                        },
                                        builder: (context, index) {
                                            final id = _ids[index];
                                            final img = _imageCache[id];
                                            if (img == null) {
                                                return PhotoViewGalleryPageOptions.customChild(
                                                    child: const Center(child: CircularProgressIndicator()),
                                                );
                                            }
                                            return PhotoViewGalleryPageOptions(
                                                imageProvider: FileImage(img.getImage()),
                                                heroAttributes: PhotoViewHeroAttributes(tag: "detailed_${img.id}"),
                                                minScale: PhotoViewComputedScale.contained * 0.5,
                                                initialScale: PhotoViewComputedScale.contained,
                                                controller: index == _currentIndex ? controller : null,
                                            );
                                        },
                                        loadingBuilder: (context, event) => const Center(
                                            child: CircularProgressIndicator(),
                                        ),
                                    ),
                            )
                        )
                    ),
                );
            }
        );
    }
}