package com.lobster.input.ui.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Pin
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.lobster.input.R
import com.lobster.input.core.device.DeviceIdentity
import com.lobster.input.core.locale.MobileLanguage
import com.lobster.input.core.locale.MobileStrings

@Composable
fun AuthScreen(
    onLoginSuccess: () -> Unit,
    viewModel: AuthViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val requireInvite by viewModel.requireInvite.collectAsState()
    val cooldownSeconds by viewModel.cooldownSeconds.collectAsState()
    val context = LocalContext.current
    
    var email by remember { mutableStateOf(viewModel.pendingCooldownEmail() ?: "") }
    var code by remember { mutableStateOf("") }
    var inviteCode by remember { mutableStateOf("") }
    var showInviteInput by remember { mutableStateOf(false) }
    
    LaunchedEffect(uiState) {
        when (uiState) {
            is AuthUiState.Success -> onLoginSuccess()
            is AuthUiState.RequireInvite -> showInviteInput = true
            else -> {}
        }
    }

    // 邮箱变化时按本地持久化时间戳恢复/刷新发码倒计时（退出 APP 重进仍生效）
    LaunchedEffect(email) {
        viewModel.refreshCooldown(email)
    }
    
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 24.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Surface(
            modifier = Modifier.size(88.dp),
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.primaryContainer,
            tonalElevation = 0.dp,
            shadowElevation = 2.dp
        ) {
            Box(contentAlignment = Alignment.Center) {
                Image(
                    painter = painterResource(R.drawable.lobster_claw),
                    contentDescription = null,
                    modifier = Modifier.size(52.dp),
                    contentScale = ContentScale.Fit
                )
            }
        }

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = MobileStrings.keyboardTitle(context),
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = mobileText(MobileStrings.currentLanguage(context), "登录后开启智能语音输入", "Sign in to start smart voice input", "Войдите, чтобы начать голосовой ввод", "로그인하여 스마트 음성 입력을 시작하세요"),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(28.dp))

        ElevatedCard(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.elevatedCardElevation(defaultElevation = 3.dp)
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                if (!showInviteInput) {
                    // 邮箱输入
                    OutlinedTextField(
                        value = email,
                        onValueChange = { email = it },
                        label = { Text(mobileText(MobileStrings.currentLanguage(context), "邮箱", "Email", "Почта", "이메일")) },
                        leadingIcon = { Icon(Icons.Default.Email, contentDescription = null) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp)
                    )

                    Spacer(modifier = Modifier.height(14.dp))

                    // 验证码输入
                    OutlinedTextField(
                        value = code,
                        onValueChange = { code = it },
                        label = { Text(mobileText(MobileStrings.currentLanguage(context), "验证码", "Code", "Код", "인증 코드")) },
                        leadingIcon = { Icon(Icons.Default.Pin, contentDescription = null) },
                        trailingIcon = {
                            TextButton(
                                onClick = { viewModel.sendCode(email) },
                                enabled = email.isNotEmpty() && cooldownSeconds <= 0 && uiState !is AuthUiState.Loading
                            ) {
                                Text(
                                    if (cooldownSeconds > 0)
                                        mobileText(MobileStrings.currentLanguage(context), "重新发送(${cooldownSeconds}s)", "Resend(${cooldownSeconds}s)", "Повтор(${cooldownSeconds}s)", "재전송(${cooldownSeconds}s)")
                                    else
                                        mobileText(MobileStrings.currentLanguage(context), "发送验证码", "Send code", "Отправить код", "코드 보내기"),
                                    style = MaterialTheme.typography.labelLarge
                                )
                            }
                        },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp)
                    )

                    Spacer(modifier = Modifier.height(24.dp))

                    // 登录按钮
                    Button(
                        onClick = { viewModel.login(email, code) },
                        enabled = email.isNotEmpty() && code.isNotEmpty() && uiState !is AuthUiState.Loading,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp),
                        shape = RoundedCornerShape(12.dp)
                    ) {
                        if (uiState is AuthUiState.Loading) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(22.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onPrimary
                            )
                        } else {
                            Text(
                                mobileText(MobileStrings.currentLanguage(context), "登录", "Sign in", "Войти", "로그인"),
                                style = MaterialTheme.typography.titleMedium
                            )
                        }
                    }
                } else {
                    // 邀请码输入
                    Text(
                        text = mobileText(MobileStrings.currentLanguage(context), "需要邀请码才能继续", "Invite code required", "Нужен код приглашения", "초대 코드가 필요합니다"),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface
                    )

                    Spacer(modifier = Modifier.height(16.dp))

                    OutlinedTextField(
                        value = inviteCode,
                        onValueChange = { inviteCode = it },
                        label = { Text(mobileText(MobileStrings.currentLanguage(context), "邀请码", "Invite code", "Код приглашения", "초대 코드")) },
                        leadingIcon = { Icon(Icons.Default.CardGiftcard, contentDescription = null) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp)
                    )

                    Spacer(modifier = Modifier.height(24.dp))

                    Button(
                        onClick = {
                            val deviceId = DeviceIdentity.deviceId(context)
                            val fingerprint = DeviceIdentity.hardwareFingerprint(context)
                            viewModel.verifyInvite(email, inviteCode, deviceId, fingerprint)
                        },
                        enabled = inviteCode.isNotEmpty() && uiState !is AuthUiState.Loading,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp),
                        shape = RoundedCornerShape(12.dp)
                    ) {
                        if (uiState is AuthUiState.Loading) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(22.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onPrimary
                            )
                        } else {
                            Text(
                                mobileText(MobileStrings.currentLanguage(context), "验证邀请码", "Verify invite", "Проверить код", "초대 코드 확인"),
                                style = MaterialTheme.typography.titleMedium
                            )
                        }
                    }
                }

                // 错误提示
                if (uiState is AuthUiState.Error) {
                    Spacer(modifier = Modifier.height(16.dp))
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.errorContainer
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                Icons.Default.ErrorOutline,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onErrorContainer,
                                modifier = Modifier.size(18.dp)
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = (uiState as AuthUiState.Error).message,
                                color = MaterialTheme.colorScheme.onErrorContainer,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                }

                // 成功提示
                if (uiState is AuthUiState.CodeSent) {
                    Spacer(modifier = Modifier.height(16.dp))
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.primaryContainer
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.size(18.dp)
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = mobileText(MobileStrings.currentLanguage(context), "验证码已发送", "Code sent", "Код отправлен", "인증 코드가 전송되었습니다"),
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun mobileText(
    language: MobileLanguage,
    zh: String,
    en: String,
    ru: String,
    ko: String,
    zhHant: String = zh,
    yue: String = zh
): String = when (language) {
    MobileLanguage.ZH_HANT -> zhHant
    MobileLanguage.YUE -> yue
    MobileLanguage.EN -> en
    MobileLanguage.RU -> ru
    MobileLanguage.KO -> ko
    else -> zh
}
