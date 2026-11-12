# Keep all ONNX Runtime classes and native JNI bindings from being stripped or obfuscated by R8
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

-keepclasseswithmembernames class * {
    native <methods>;
}
