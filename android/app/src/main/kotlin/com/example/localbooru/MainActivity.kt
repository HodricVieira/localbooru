package com.auser.localbooru

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import ai.onnxruntime.OnnxJavaType
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
