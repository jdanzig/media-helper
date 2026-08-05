package com.example.mediahelper

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.example.mediahelper.ui.RootTabView
import com.example.mediahelper.ui.theme.MediaHelperTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MediaHelperTheme {
                RootTabView()
            }
        }
    }
}
