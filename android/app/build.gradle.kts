plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.queuecare.hospitalqueue"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.queuecare.hospitalqueue"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val storeFilePath = System.getenv("QUEUECARE_UPLOAD_KEYSTORE")
            if (!storeFilePath.isNullOrBlank()) {
                storeFile = file(storeFilePath)
                storePassword = System.getenv("QUEUECARE_UPLOAD_STORE_PASSWORD")
                keyAlias = System.getenv("QUEUECARE_UPLOAD_KEY_ALIAS")
                keyPassword = System.getenv("QUEUECARE_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val storeFilePath = System.getenv("QUEUECARE_UPLOAD_KEYSTORE")
            if (!storeFilePath.isNullOrBlank()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
