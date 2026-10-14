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

# ---- JNA（UniFFI 生成的绑定靠它调用 Rust cdylib）----
# JNA 通过反射注册 native 方法，保留整个包及相关注解
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { *; }
-dontwarn java.awt.**
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations

# ---- UniFFI 生成的绑定 ----
# 包含 JNA 接口、Structure 定义与 FfiConverter，均依赖反射/注解
-keep class uniffi.** { *; }
-keepclassmembers class uniffi.** { *; }
