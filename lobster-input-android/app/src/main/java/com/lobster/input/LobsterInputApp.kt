package com.lobster.input

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class LobsterInputApp : Application() {
    
    override fun onCreate() {
        super.onCreate()
        instance = this
    }
    
    companion object {
        lateinit var instance: LobsterInputApp
            private set
    }
}
