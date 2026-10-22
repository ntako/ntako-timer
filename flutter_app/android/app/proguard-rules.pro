# flutter_local_notifications stores scheduled notifications with Gson and
# reads them back in its boot / package-replaced receiver. Without these
# rules R8 strips the generic signatures Gson needs, and the app crashes
# after every reboot or update (IllegalStateException: TypeToken must be
# created with a type argument). Rules from the plugin's example app.
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
# The plugin's notification models are (de)serialized by Gson.
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
