package com.auser.localbooru

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.Os
import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "com.auser.localbooru/waifutagger"
    private val STORAGE_CHANNEL = "com.auser.localbooru/storage"
    private val PICK_MEDIA_REQUEST_CODE = 9401
    private val PICK_DIR_REQUEST_CODE = 9402

    private val executor = Executors.newSingleThreadExecutor()

    private var ortEnv: OrtEnvironment? = null
    private var ortSession: OrtSession? = null
    private var loadedModelPath: String? = null

    private var pendingPickMediaResult: MethodChannel.Result? = null
    private var pendingPickDirResult: MethodChannel.Result? = null
    private val pickedFileUris = ConcurrentHashMap<String, Uri>()
    private val pickedTreeUris = ConcurrentHashMap<String, Uri>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "runInference" -> {
                    val modelPath = call.argument<String>("modelPath")
                    val imagePath = call.argument<String>("imagePath")
                    if (modelPath == null || imagePath == null) {
                        result.error("INVALID_ARGS", "modelPath and imagePath are required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val probabilities = runOnnxInference(modelPath, imagePath)
                            runOnUiThread {
                                result.success(probabilities)
                            }
                        } catch (t: Throwable) {
                            runOnUiThread {
                                result.error("INFERENCE_ERROR", t.message ?: "Unknown ONNX error", t.stackTraceToString())
                            }
                        }
                    }
                }
                "releaseModel" -> {
                    executor.execute {
                        try {
                            ortSession?.close()
                            ortSession = null
                            loadedModelPath = null
                            System.gc()
                            runOnUiThread { result.success(true) }
                        } catch (t: Throwable) {
                            runOnUiThread { result.error("RELEASE_ERROR", t.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickMediaFiles" -> {
                    if (pendingPickMediaResult != null) {
                        result.error("ALREADY_ACTIVE", "A file picker operation is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingPickMediaResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        startActivityForResult(intent, PICK_MEDIA_REQUEST_CODE)
                    } catch (t: Throwable) {
                        pendingPickMediaResult = null
                        result.error("PICK_ERROR", t.message, null)
                    }
                }
                "pickDirectory" -> {
                    if (pendingPickDirResult != null) {
                        result.error("ALREADY_ACTIVE", "A directory picker operation is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingPickDirResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                            )
                        }
                        startActivityForResult(intent, PICK_DIR_REQUEST_CODE)
                    } catch (t: Throwable) {
                        pendingPickDirResult = null
                        result.error("PICK_DIR_ERROR", t.message, null)
                    }
                }
                "deleteSourceFile" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val targetPath = call.argument<String>("targetPath")
                    if (sourcePath.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        val deleted = deleteSourceFileNative(sourcePath, targetPath)
                        runOnUiThread {
                            result.success(deleted)
                        }
                    }
                }
                "deleteEmptyDirectory" -> {
                    val folderPath = call.argument<String>("folderPath")
                    if (folderPath.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        val deleted = deleteEmptyDirectoryNative(folderPath)
                        runOnUiThread {
                            result.success(deleted)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_MEDIA_REQUEST_CODE) {
            val callback = pendingPickMediaResult
            pendingPickMediaResult = null
            if (callback == null) return
            if (resultCode != Activity.RESULT_OK || data == null) {
                callback.success(null)
                return
            }
            val uris = mutableListOf<Uri>()
            val clipData = data.clipData
            if (clipData != null) {
                for (i in 0 until clipData.itemCount) {
                    clipData.getItemAt(i)?.uri?.let { uris.add(it) }
                }
            } else {
                data.data?.let { uris.add(it) }
            }
            executor.execute {
                val resolvedPaths = ArrayList<String>()
                for (uri in uris) {
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                    } catch (_: Throwable) {}
                    val path = resolveRealPathFromUri(uri)
                    if (path != null) {
                        rememberPickedFileUri(path, uri)
                        resolvedPaths.add(path)
                    }
                }
                runOnUiThread {
                    callback.success(resolvedPaths)
                }
            }
        } else if (requestCode == PICK_DIR_REQUEST_CODE) {
            val callback = pendingPickDirResult
            pendingPickDirResult = null
            if (callback == null) return
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                callback.success(null)
                return
            }
            val treeUri = data.data!!
            executor.execute {
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Throwable) {}
                val dirPath = resolveDirectoryPathFromTreeUri(treeUri)
                if (dirPath != null) {
                    rememberPickedTreeUri(dirPath, treeUri)
                }
                runOnUiThread {
                    callback.success(dirPath)
                }
            }
        }
    }

    private fun rememberPickedFileUri(path: String, uri: Uri) {
        pickedFileUris[path] = uri
        normalizeAndroidStoragePath(path)?.let { pickedFileUris[it] = uri }
        try {
            pickedFileUris[File(path).canonicalPath] = uri
        } catch (_: Throwable) {}
    }

    private fun rememberPickedTreeUri(folderPath: String, treeUri: Uri) {
        val clean = folderPath.trimEnd('/', '\\')
        pickedTreeUris[clean] = treeUri
        normalizeAndroidStoragePath(clean)?.let { pickedTreeUris[it.trimEnd('/', '\\')] = treeUri }
        try {
            pickedTreeUris[File(clean).canonicalPath.trimEnd('/', '\\')] = treeUri
        } catch (_: Throwable) {}
    }

    private fun normalizeAndroidStoragePath(rawPath: String?): String? {
        if (rawPath.isNullOrBlank()) return null
        val path = rawPath.trim()
        if (path.endsWith(" (deleted)")) return null

        val primaryRoot = Environment.getExternalStorageDirectory().absolutePath.trimEnd('/')
        val primaryPrefixes = listOf(
            "/mnt/user/0/emulated/0",
            "/mnt/pass_through/0/emulated/0",
            "/mnt/runtime/write/emulated/0",
            "/mnt/runtime/read/emulated/0",
            "/mnt/runtime/default/emulated/0",
            "/mnt/runtime/full/emulated/0",
            "/data/media/0",
            "/mnt/sdcard",
            "/sdcard"
        )
        for (prefix in primaryPrefixes) {
            if (path == prefix) return primaryRoot
            if (path.startsWith("$prefix/")) {
                return primaryRoot + path.removePrefix(prefix)
            }
        }

        val sdVolumeRegex = Regex("^/(?:mnt/user/0|mnt/pass_through/0|mnt/runtime/(?:write|read|default|full)|mnt/media_rw)/([^/]+)(/.*)?$")
        val match = sdVolumeRegex.matchEntire(path)
        if (match != null) {
            val volumeId = match.groupValues[1]
            val rest = match.groupValues[2]
            if (!volumeId.equals("emulated", ignoreCase = true) && !volumeId.equals("self", ignoreCase = true)) {
                return "/storage/$volumeId$rest"
            }
        }
        return path
    }

    private fun queryDataColumn(uri: Uri, selection: String?, selectionArgs: Array<String>?): String? {
        val projection = arrayOf(MediaStore.MediaColumns.DATA)
        try {
            contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (idx >= 0) {
                        val value = cursor.getString(idx)
                        if (!value.isNullOrBlank()) return value
                    }
                }
            }
        } catch (_: Throwable) {}
        return null
    }

    private fun resolvePathViaProcFd(uri: Uri): String? {
        try {
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                val link = Os.readlink("/proc/self/fd/${pfd.fd}")
                val normalized = normalizeAndroidStoragePath(link)
                if (normalized != null && File(normalized).exists()) {
                    return File(normalized).absolutePath
                }
                if (!link.endsWith(" (deleted)") && File(link).exists()) {
                    return File(link).absolutePath
                }
            }
        } catch (_: Throwable) {}
        return null
    }

    private fun resolveRealPathFromUri(uri: Uri): String? {
        if (uri.scheme.equals("file", ignoreCase = true)) {
            val p = uri.path
            if (!p.isNullOrBlank() && File(p).exists()) return File(p).absolutePath
        }

        if (DocumentsContract.isDocumentUri(this, uri)) {
            try {
                val docId = DocumentsContract.getDocumentId(uri)
                when (uri.authority) {
                    "com.android.externalstorage.documents" -> {
                        val split = docId.split(":", limit = 2)
                        val type = split[0]
                        val rel = if (split.size > 1) split[1] else ""
                        val candidate = if (type.equals("primary", ignoreCase = true)) {
                            "${Environment.getExternalStorageDirectory().absolutePath}/$rel"
                        } else {
                            "/storage/$type/$rel"
                        }
                        if (File(candidate).exists()) return File(candidate).absolutePath
                    }
                    "com.android.providers.media.documents" -> {
                        val split = docId.split(":", limit = 2)
                        if (split.size == 2) {
                            val mediaId = split[1]
                            val contentUri = when (split[0]) {
                                "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                                "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                                "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                                else -> MediaStore.Files.getContentUri("external")
                            }
                            queryDataColumn(contentUri, "_id=?", arrayOf(mediaId))?.let {
                                if (File(it).exists()) return File(it).absolutePath
                            }
                        }
                    }
                    "com.android.providers.downloads.documents" -> {
                        if (docId.startsWith("raw:")) {
                            val rawPath = docId.removePrefix("raw:")
                            if (File(rawPath).exists()) return File(rawPath).absolutePath
                        }
                        val cleanId = docId.removePrefix("msf:")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            queryDataColumn(MediaStore.Downloads.EXTERNAL_CONTENT_URI, "_id=?", arrayOf(cleanId))?.let {
                                if (File(it).exists()) return File(it).absolutePath
                            }
                        }
                        queryDataColumn(MediaStore.Files.getContentUri("external"), "_id=?", arrayOf(cleanId))?.let {
                            if (File(it).exists()) return File(it).absolutePath
                        }
                        val numericId = cleanId.toLongOrNull()
                        if (numericId != null) {
                            val downloadUriPrefixes = listOf(
                                "content://downloads/public_downloads",
                                "content://downloads/my_downloads",
                                "content://downloads/all_downloads"
                            )
                            for (prefix in downloadUriPrefixes) {
                                val dlUri = ContentUris.withAppendedId(Uri.parse(prefix), numericId)
                                queryDataColumn(dlUri, null, null)?.let {
                                    if (File(it).exists()) return File(it).absolutePath
                                }
                            }
                        }
                    }
                }
            } catch (_: Throwable) {}
        }

        queryDataColumn(uri, null, null)?.let {
            if (File(it).exists()) return File(it).absolutePath
        }

        resolvePathViaProcFd(uri)?.let { return it }

        // Fallback for cloud-only files that do not reside on local storage
        return try {
            var displayName = "picked_${System.currentTimeMillis()}"
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrBlank()) displayName = name
                    }
                }
            }
            val dir = File(cacheDir, "picked_media")
            if (!dir.exists()) dir.mkdirs()
            val destFile = File(dir, displayName)
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output)
                }
            }
            if (destFile.exists() && destFile.length() > 0) destFile.absolutePath else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun resolveDirectoryPathFromTreeUri(treeUri: Uri): String? {
        try {
            val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
            if (treeDocId.startsWith("raw:")) {
                val raw = treeDocId.removePrefix("raw:")
                if (File(raw).exists()) return File(raw).absolutePath
            }
            val split = treeDocId.split(":", limit = 2)
            val type = split[0]
            val rel = if (split.size > 1) split[1].trim('/') else ""
            if (type.equals("primary", ignoreCase = true)) {
                val base = Environment.getExternalStorageDirectory().absolutePath.trimEnd('/')
                val candidate = if (rel.isEmpty()) base else "$base/$rel"
                if (File(candidate).exists()) return File(candidate).absolutePath
            } else if (split.size == 2) {
                val candidate = if (rel.isEmpty()) "/storage/$type" else "/storage/$type/$rel"
                if (File(candidate).exists()) return File(candidate).absolutePath
            }

            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
            resolvePathViaProcFd(docUri)?.let { return it }
        } catch (_: Throwable) {}
        return null
    }

    private fun deleteSourceFileNative(sourcePath: String, targetPath: String?): Boolean {
        val normalizedPath = normalizeAndroidStoragePath(sourcePath) ?: sourcePath
        val file = File(normalizedPath)
        val canonicalPath = try { file.canonicalPath } catch (_: Throwable) { normalizedPath }

        val pickedUri = pickedFileUris[sourcePath]
            ?: pickedFileUris[normalizedPath]
            ?: pickedFileUris[canonicalPath]

        // 1. Direct filesystem deletion
        try {
            if (file.exists()) file.delete()
        } catch (_: Throwable) {}
        try {
            val rawFile = File(sourcePath)
            if (rawFile.exists()) rawFile.delete()
        } catch (_: Throwable) {}

        // 2. If picked via SAF document picker, also delete via DocumentsContract if needed
        if (pickedUri != null) {
            if (file.exists() || File(sourcePath).exists()) {
                try {
                    DocumentsContract.deleteDocument(contentResolver, pickedUri)
                } catch (_: Throwable) {
                    try { contentResolver.delete(pickedUri, null, null) } catch (_: Throwable) {}
                }
            }
            pickedFileUris.remove(sourcePath)
            pickedFileUris.remove(normalizedPath)
            pickedFileUris.remove(canonicalPath)
        }

        // 3. If inside a picked SAF directory tree, delete via child DocumentUri if still present
        if (file.exists()) {
            for ((folderPath, treeUri) in pickedTreeUris.entries) {
                val normFolder = (normalizeAndroidStoragePath(folderPath) ?: folderPath).trimEnd('/', '\\')
                if (normalizedPath.startsWith("$normFolder/") || canonicalPath.startsWith("$normFolder/")) {
                    val relSubpath = if (normalizedPath.startsWith("$normFolder/")) {
                        normalizedPath.removePrefix("$normFolder/")
                    } else {
                        canonicalPath.removePrefix("$normFolder/")
                    }.trimStart('/', '\\')
                    if (relSubpath.isNotEmpty()) {
                        try {
                            val treeDocId = DocumentsContract.getTreeDocumentId(treeUri).trimEnd('/')
                            val childDocId = "$treeDocId/$relSubpath"
                            val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childDocId)
                            DocumentsContract.deleteDocument(contentResolver, childUri)
                        } catch (_: Throwable) {}
                    }
                }
            }
        }

        // 4. Remove from MediaStore (also deletes the file on disk via MediaProvider if still present,
        //    and removes stale Gallery thumbnails when already unlinked)
        val pathsToClean = linkedSetOf(sourcePath, normalizedPath, canonicalPath)
        val mediaUris = listOf(
            MediaStore.Files.getContentUri("external"),
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        )
        for (p in pathsToClean) {
            for (mediaUri in mediaUris) {
                try {
                    contentResolver.delete(
                        mediaUri,
                        "${MediaStore.MediaColumns.DATA} = ?",
                        arrayOf(p)
                    )
                } catch (_: Throwable) {}
            }
        }

        // 5. Final direct delete check
        try {
            if (file.exists()) file.delete()
        } catch (_: Throwable) {}
        try {
            val rawFile = File(sourcePath)
            if (rawFile.exists()) rawFile.delete()
        } catch (_: Throwable) {}

        // 6. Notify MediaScanner of both the deleted source path and new destination path
        try {
            val scanPaths = mutableListOf(normalizedPath)
            if (!targetPath.isNullOrBlank()) scanPaths.add(targetPath)
            MediaScannerConnection.scanFile(
                applicationContext,
                scanPaths.toTypedArray(),
                null,
                null
            )
        } catch (_: Throwable) {}

        return !file.exists() && !File(sourcePath).exists()
    }

    private fun deleteEmptyDirectoryNative(folderPath: String): Boolean {
        val normalizedPath = (normalizeAndroidStoragePath(folderPath) ?: folderPath).trimEnd('/', '\\')
        val dir = File(normalizedPath)
        if (!dir.exists() || !dir.isDirectory) return true

        val remaining = dir.listFiles()
        if (remaining != null && remaining.isNotEmpty()) {
            // Only remove trivial OS metadata files (.nomedia, Thumbs.db, .DS_Store) if no other files exist
            val trivialNames = setOf(".nomedia", "thumbs.db", ".ds_store", "desktop.ini")
            val allTrivial = remaining.all { it.isFile && trivialNames.contains(it.name.lowercase()) }
            if (allTrivial) {
                for (f in remaining) {
                    try { f.delete() } catch (_: Throwable) {}
                }
            } else {
                return false
            }
        }

        try {
            dir.delete()
        } catch (_: Throwable) {}

        if (dir.exists()) {
            val treeUri = pickedTreeUris[folderPath.trimEnd('/', '\\')]
                ?: pickedTreeUris[normalizedPath]
            if (treeUri != null) {
                try {
                    val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
                    DocumentsContract.deleteDocument(contentResolver, docUri)
                } catch (_: Throwable) {}
            }
        }

        try {
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(normalizedPath),
                null,
                null
            )
        } catch (_: Throwable) {}

        return !dir.exists()
    }

    private fun getOrCreateSession(modelPath: String): OrtSession {
        val modelFile = File(modelPath)
        if (!modelFile.exists() || modelFile.length() < 50L * 1024L * 1024L) {
            throw IllegalStateException("Arquivo do modelo ONNX ausente ou incompleto (${modelFile.length()} bytes). Rebaixe o modelo nas Configurações.")
        }
        if (ortEnv == null) {
            ortEnv = OrtEnvironment.getEnvironment()
        }
        if (ortSession != null && loadedModelPath == modelPath) {
            return ortSession!!
        }
        try {
            ortSession?.close()
        } catch (_: Throwable) {}
        ortSession = null
        loadedModelPath = null
        System.gc()

        OrtSession.SessionOptions().use { options ->
            // Disable heavy C++ graph rewrites & arena pre-allocation on pre-quantized mobile models
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.NO_OPT)
            options.setMemoryPatternOptimization(false)
            options.setCPUArenaAllocator(false)
            options.setIntraOpNumThreads(2)
            options.setInterOpNumThreads(1)
            ortSession = ortEnv!!.createSession(modelPath, options)
        }
        loadedModelPath = modelPath
        return ortSession!!
    }

    private fun prepareBitmap448(imagePath: String, targetSize: Int = 448): Bitmap {
        val boundsOptions = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        BitmapFactory.decodeFile(imagePath, boundsOptions)
        if (boundsOptions.outWidth <= 0 || boundsOptions.outHeight <= 0) {
            File(imagePath).inputStream().use {
                BitmapFactory.decodeStream(it, null, boundsOptions)
            }
        }
        if (boundsOptions.outWidth <= 0 || boundsOptions.outHeight <= 0) {
            throw IllegalArgumentException("Could not decode image bounds at $imagePath")
        }

        var sampleSize = 1
        while (boundsOptions.outWidth / (sampleSize * 2) >= targetSize &&
               boundsOptions.outHeight / (sampleSize * 2) >= targetSize) {
            sampleSize *= 2
        }

        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }

        val original = BitmapFactory.decodeFile(imagePath, decodeOptions)
            ?: File(imagePath).inputStream().use { BitmapFactory.decodeStream(it, null, decodeOptions) }
            ?: throw IllegalArgumentException("Could not decode image at $imagePath")

        val bmp = Bitmap.createBitmap(targetSize, targetSize, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.WHITE)

        val width = original.width.toFloat()
        val height = original.height.toFloat()
        val scale = targetSize.toFloat() / maxOf(width, height)
        val scaledWidth = width * scale
        val scaledHeight = height * scale
        val left = (targetSize - scaledWidth) / 2f
        val top = (targetSize - scaledHeight) / 2f

        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        canvas.drawBitmap(original, null, RectF(left, top, left + scaledWidth, top + scaledHeight), paint)
        if (original != bmp) {
            original.recycle()
        }
        return bmp
    }

    private fun extractFloatArray(outputValue: Any?): FloatArray {
        return when (outputValue) {
            is FloatArray -> outputValue
            is Array<*> -> {
                val first = outputValue.firstOrNull()
                if (first is FloatArray) first
                else throw IllegalStateException("Unexpected nested ONNX output type: ${first?.javaClass}")
            }
            else -> throw IllegalStateException("Unexpected ONNX output type: ${outputValue?.javaClass}")
        }
    }

    private fun runOnnxInference(modelPath: String, imagePath: String): FloatArray {
        val session = getOrCreateSession(modelPath)
        val env = ortEnv!!

        val inputName = session.inputNames.first()
        val inputNodeInfo = session.inputInfo[inputName]?.info as? TensorInfo
        val isUint8 = inputNodeInfo?.type == OnnxJavaType.UINT8 ||
            inputNodeInfo?.onnxType == TensorInfo.OnnxTensorType.ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8 ||
            (inputNodeInfo == null && modelPath.contains("mobile", ignoreCase = true))
        val shape = inputNodeInfo?.shape ?: longArrayOf(1, 448, 448, 3)

        val targetSize = 448
        val bmp = prepareBitmap448(imagePath, targetSize)
        val pixels = IntArray(targetSize * targetSize)
        bmp.getPixels(pixels, 0, targetSize, 0, 0, targetSize, targetSize)
        bmp.recycle()

        val isChannelsFirst = (shape.size == 4 && shape[1] == 3L) || (shape.size == 3 && shape[0] == 3L)
        val tensorShape: LongArray = when (shape.size) {
            1 -> longArrayOf((targetSize * targetSize * 3).toLong())
            3 -> if (isChannelsFirst) longArrayOf(3, targetSize.toLong(), targetSize.toLong())
                 else longArrayOf(targetSize.toLong(), targetSize.toLong(), 3)
            else -> if (isChannelsFirst) longArrayOf(1, 3, targetSize.toLong(), targetSize.toLong())
                    else longArrayOf(1, targetSize.toLong(), targetSize.toLong(), 3)
        }

        // Keep a strong reference to rawByteBuffer across the entire session.run() lifecycle
        // so the JVM GC never collects the direct buffer while native C++ JNI is reading it.
        val rawByteBuffer: ByteBuffer
        val inputTensor: OnnxTensor = if (isUint8) {
            // WaifuTagger -mobile ONNX format: UINT8 RGB [1, 448, 448, 3]
            rawByteBuffer = ByteBuffer.allocateDirect(1 * targetSize * targetSize * 3).order(ByteOrder.nativeOrder())
            if (isChannelsFirst) {
                for (c in 0..2) {
                    for (pixel in pixels) {
                        val v = when (c) {
                            0 -> (pixel shr 16) and 0xFF
                            1 -> (pixel shr 8) and 0xFF
                            else -> pixel and 0xFF
                        }
                        rawByteBuffer.put(v.toByte())
                    }
                }
            } else {
                for (pixel in pixels) {
                    val r = (pixel shr 16) and 0xFF
                    val g = (pixel shr 8) and 0xFF
                    val b = pixel and 0xFF
                    rawByteBuffer.put(r.toByte())
                    rawByteBuffer.put(g.toByte())
                    rawByteBuffer.put(b.toByte())
                }
            }
            rawByteBuffer.rewind()
            OnnxTensor.createTensor(env, rawByteBuffer, tensorShape, OnnxJavaType.UINT8)
        } else {
            // Standard SmilingWolf WD14 ONNX format: FLOAT32 BGR [1, 448, 448, 3]
            rawByteBuffer = ByteBuffer.allocateDirect(1 * targetSize * targetSize * 3 * 4).order(ByteOrder.nativeOrder())
            val floatBuffer = rawByteBuffer.asFloatBuffer()
            if (isChannelsFirst) {
                for (c in 0..2) {
                    for (pixel in pixels) {
                        val v = when (c) {
                            0 -> (pixel and 0xFF).toFloat() // B
                            1 -> ((pixel shr 8) and 0xFF).toFloat() // G
                            else -> ((pixel shr 16) and 0xFF).toFloat() // R
                        }
                        floatBuffer.put(v)
                    }
                }
            } else {
                for (pixel in pixels) {
                    val r = ((pixel shr 16) and 0xFF).toFloat()
                    val g = ((pixel shr 8) and 0xFF).toFloat()
                    val b = (pixel and 0xFF).toFloat()
                    floatBuffer.put(b)
                    floatBuffer.put(g)
                    floatBuffer.put(r)
                }
            }
            floatBuffer.rewind()
            OnnxTensor.createTensor(env, floatBuffer, tensorShape)
        }

        val outputProbs: FloatArray = inputTensor.use { tensor ->
            session.run(Collections.singletonMap(inputName, tensor)).use { results ->
                val firstResult = results[0]
                if (firstResult is OnnxTensor) {
                    val fb = firstResult.floatBuffer
                    if (fb != null) {
                        fb.rewind()
                        val arr = FloatArray(fb.remaining())
                        fb.get(arr)
                        arr
                    } else {
                        extractFloatArray(firstResult.value)
                    }
                } else {
                    extractFloatArray(firstResult.value)
                }
            }
        }

        // Prevent GC of rawByteBuffer before native execution finishes
        if (rawByteBuffer.capacity() < 0) {
            throw IllegalStateException("Unreachable")
        }
        return outputProbs
    }
}
