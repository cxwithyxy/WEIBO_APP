# ---- Gson：反射用到的模型类必须保留，否则 R8 混淆后会解析失败 ----
-keep class com.cx.weibo.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses,EnclosingMethod
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# ---- OkHttp / Okio（Coil 网络层）----
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# ---- Coil ----
-dontwarn coil3.**
