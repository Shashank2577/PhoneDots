# LiteRT-LM calls back into Kotlin from JNI and reflects over tool classes.
-keep class com.google.ai.edge.litertlm.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
# Desert Ant model bridges are looked up by JNI name.
-keep class ai.desertant.** { *; }
-dontwarn com.google.ai.edge.litertlm.**
-dontwarn ai.desertant.**
