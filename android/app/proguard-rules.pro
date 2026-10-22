# Release builds run R8 with optimisation (proguard-android-optimize.txt).
# Plugins below rely on reflection or JNI and do not ship complete consumer
# rules. Firebase, AndroidX/Media3 (video_player, just_audio) and Tink
# (flutter_secure_storage) ship their own; SQLCipher, vodozemac and webcrypto
# are Dart FFI (no JVM code).

# flutter_local_notifications stores scheduled notifications as Gson JSON of
# its model classes (reminders, scheduled messages): field names must stay.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Flutter embedding entry points looked up by name from native code and
# plugin registrants (kept by the Flutter Gradle plugin; listed for clarity).
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# ChatLoom's own native code: the FCM service and the round-video plugin are
# referenced from the manifest and MainActivity; JNI-free.
-keep class pl.personal.chatloom.** { *; }
