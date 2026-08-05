package com.example.mediahelper

import android.app.Application
import com.example.mediahelper.store.SecureStore

class MediaHelperApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SecureStore.init(this)
    }
}
