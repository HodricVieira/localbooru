package com.auser.localbooru

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.Collections
import java.util.concurrent.Executors

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "com.auser.localbooru/waifutagger"
    private val executor = Executors.newSingleThreadExecutor()

    private var ortEnv: OrtEnvironment? = null
    private var ortSession: OrtSession? = null
    private var loadedModelPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "runInference" -> {
                    val modelPath = call.argument<String>("modelPath")
                    val imagePath = call.argument<String>("imagePath")
                    val imageBytes = call.argument<ByteArray>("imageBytes")
                    if (modelPath == null || (imagePath == null && imageBytes == null)) {
                        result.error("INVALID_ARGS", "modelPath and imagePath/imageBytes are required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val probabilities = runOnnxInference(modelPath, imagePath, imageBytes)
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
                            runOnUiThread { result.success(true) }
                        } catch (t: Throwable) {
                            runOnUiThread { result.error("RELEASE_ERROR", t.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getOrCreateSession(modelPath: String): OrtSession {
        if (ortEnv == null) {
            ortEnv = OrtEnvironment.getEnvironment()
        }
        if (ortSession != null && loadedModelPath == modelPath) {
            return ortSession!!
        }
        ortSession?.close()
        val options = OrtSession.SessionOptions()
        options.setIntraOpNumThreads(2)
        ortSession = ortEnv!!.createSession(modelPath, options)
        loadedModelPath = modelPath
        return ortSession!!
    }

    private fun prepareBitmap448(imagePath: String?, imageBytes: ByteArray?, targetSize: Int = 448): Bitmap {
        val boundsOptions = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        if (imageBytes != null && imageBytes.isNotEmpty()) {
            BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, boundsOptions)
        }
        if ((boundsOptions.outWidth <= 0 || boundsOptions.outHeight <= 0) && imagePath != null) {
            BitmapFactory.decodeFile(imagePath, boundsOptions)
        }
        if ((boundsOptions.outWidth <= 0 || boundsOptions.outHeight <= 0) && imagePath != null) {
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

        var original: Bitmap? = null
        if (imageBytes != null && imageBytes.isNotEmpty()) {
            original = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, decodeOptions)
        }
        if (original == null && imagePath != null) {
            original = BitmapFactory.decodeFile(imagePath, decodeOptions)
        }
        if (original == null && imagePath != null) {
            original = File(imagePath).inputStream().use {
                BitmapFactory.decodeStream(it, null, decodeOptions)
            }
        }
        if (original == null) {
            throw IllegalArgumentException("Could not decode image at $imagePath")
        }
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

    private fun runOnnxInference(modelPath: String, imagePath: String?, imageBytes: ByteArray?): List<Double> {
        val session = getOrCreateSession(modelPath)
        val env = ortEnv!!

        val inputName = session.inputNames.first()
        val inputNodeInfo = session.inputInfo[inputName]?.info as? TensorInfo
        val isUint8 = inputNodeInfo?.type?.name?.contains("UINT8") == true
        val shape = inputNodeInfo?.shape ?: longArrayOf(1, 448, 448, 3)

        val targetSize = 448
        val bmp = prepareBitmap448(imagePath, imageBytes, targetSize)
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

        val inputTensor: OnnxTensor = if (isUint8) {
            // WaifuTagger -mobile ONNX format: UINT8 RGB [1, 448, 448, 3] (or [1, 3, 448, 448])
            val byteBuffer = ByteBuffer.allocateDirect(1 * targetSize * targetSize * 3).order(ByteOrder.nativeOrder())
            if (isChannelsFirst) {
                for (c in 0..2) {
                    for (pixel in pixels) {
                        val v = when (c) {
                            0 -> (pixel shr 16) and 0xFF
                            1 -> (pixel shr 8) and 0xFF
                            else -> pixel and 0xFF
                        }
                        byteBuffer.put(v.toByte())
                    }
                }
            } else {
                for (pixel in pixels) {
                    val r = (pixel shr 16) and 0xFF
                    val g = (pixel shr 8) and 0xFF
                    val b = pixel and 0xFF
                    byteBuffer.put(r.toByte())
                    byteBuffer.put(g.toByte())
                    byteBuffer.put(b.toByte())
                }
            }
            byteBuffer.rewind()
            OnnxTensor.createTensor(env, byteBuffer, tensorShape, ai.onnxruntime.OnnxJavaType.UINT8)
        } else {
            // Standard SmilingWolf WD14 ONNX format: FLOAT32 BGR [1, 448, 448, 3] (or [1, 3, 448, 448])
            val floatBuffer = ByteBuffer.allocateDirect(1 * targetSize * targetSize * 3 * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
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

        inputTensor.use { tensor ->
            session.run(Collections.singletonMap(inputName, tensor)).use { results ->
                val firstResult = results[0]
                if (firstResult is OnnxTensor) {
                    val fb = firstResult.floatBuffer
                    if (fb != null) {
                        fb.rewind()
                        val arr = FloatArray(fb.remaining())
                        fb.get(arr)
                        return arr.map { it.toDouble() }
                    }
                }
                val outputValue = firstResult.value
                val probs: FloatArray = when (outputValue) {
                    is Array<*> -> (outputValue[0] as FloatArray)
                    is FloatArray -> outputValue
                    else -> throw IllegalStateException("Unexpected ONNX output type: ${outputValue?.javaClass}")
                }
                return probs.map { it.toDouble() }
            }
        }
    }
}

