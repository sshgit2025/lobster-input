package com.lobster.input.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.*
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.lobster.input.LobsterInputApp
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.data.local.AuthSession
import com.lobster.input.ui.auth.AuthScreen
import com.lobster.input.ui.main.MainScreen

@Composable
fun LobsterApp() {
    val navController = rememberNavController()
    val isLoggedIn by rememberSessionLoggedIn()

    LaunchedEffect(isLoggedIn) {
        val target = if (isLoggedIn) "main" else "auth"
        navController.navigate(target) {
            popUpTo(navController.graph.startDestinationId) { inclusive = true }
            launchSingleTop = true
        }
    }
    
    NavHost(
        navController = navController,
        startDestination = if (isLoggedIn) "main" else "auth"
    ) {
        composable("auth") {
            AuthScreen(
                onLoginSuccess = {
                    navController.navigate("main") {
                        popUpTo("auth") { inclusive = true }
                    }
                }
            )
        }
        
        composable("main") {
            MainScreen(
                onLogout = {
                    navController.navigate("auth") {
                        popUpTo("main") { inclusive = true }
                    }
                }
            )
        }
    }
}

@Composable
private fun rememberSessionLoggedIn(): State<Boolean> {
    val context = LobsterInputApp.instance
    val prefs = remember {
        context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
    }
    val loggedIn = remember { mutableStateOf(AuthSession.isLoggedIn(context)) }
    DisposableEffect(prefs) {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            // token 现存放于加密 key；旧明文 key 在迁移/登出时也会变化。
            // key 为 null 表示批量变更（如 clear），同样需要重新计算登录态。
            if (key == null ||
                key == ApiConfig.KEY_AUTH_TOKEN_ENC ||
                key == ApiConfig.KEY_AUTH_TOKEN
            ) {
                loggedIn.value = AuthSession.isLoggedIn(context)
            }
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return loggedIn
}
