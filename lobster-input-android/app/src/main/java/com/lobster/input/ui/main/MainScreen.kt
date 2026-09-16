package com.lobster.input.ui.main

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.lobster.input.core.history.MobileHistoryRecord
import com.lobster.input.core.history.MobileHistoryStatus
import com.lobster.input.BuildConfig
import com.lobster.input.core.history.MobileHistoryStore
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.keyboard.typing.coordinator.TypingPreferences
import com.lobster.input.core.update.AndroidUpdateCheckResult
import com.lobster.input.core.update.AndroidInstalledVersion
import com.lobster.input.core.update.AndroidUpdateManager
import com.lobster.input.core.update.AndroidUpdateManifest
import com.lobster.input.data.model.HotWordItem
import com.lobster.input.data.model.PERSONA_MAX_COUNT
import com.lobster.input.data.model.PERSONA_PROMPT_MAX_LENGTH
import com.lobster.input.data.model.PaymentBillingOption
import com.lobster.input.data.model.PaymentCatalogResponse
import com.lobster.input.data.model.PaymentCreditsTopup
import com.lobster.input.data.model.PaymentSubscriptionPlan
import com.lobster.input.data.model.PersonaItem
import com.lobster.input.data.model.PersonaPrompts
import com.lobster.input.core.locale.MobileLanguage
import com.lobster.input.core.locale.MobileStrings
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

// ---- 统一视觉令牌(纯样式) ----
private val LobsterCardShape = RoundedCornerShape(16.dp)
private val LobsterButtonShape = RoundedCornerShape(12.dp)
private val LobsterFieldShape = RoundedCornerShape(12.dp)
private val LobsterChipShape = RoundedCornerShape(50)

@Composable
private fun lobsterCardColors() = CardDefaults.elevatedCardColors(
    containerColor = MaterialTheme.colorScheme.surface
)

@Composable
private fun lobsterCardElevation() = CardDefaults.elevatedCardElevation(defaultElevation = 2.dp)

// 水波品牌渐变(与键盘录音涟漪钮一致)
private val LobsterBrandGradient = Brush.linearGradient(
    colors = listOf(Color(0xFF2BA7E0), Color(0xFF0A84C4))
)

/** 分组小标题:像精致设置 App 那样的区块标签。 */
@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.6.sp,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 6.dp, top = 8.dp, bottom = 2.dp)
    )
}

/** 分组卡片容器:白底柔和圆角,内部行用细分割线分隔。 */
@Composable
private fun SettingsGroup(content: @Composable ColumnScope.() -> Unit) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        Column(content = content)
    }
}

/** 统一设置行:左侧圆角图标徽章 + 标题/副标题 + 尾部控件或箭头。 */
@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    trailing: @Composable (() -> Unit)? = null
) {
    val rowModifier = if (onClick != null && enabled) {
        Modifier.fillMaxWidth().clickable(onClick = onClick)
    } else {
        Modifier.fillMaxWidth()
    }
    Row(
        modifier = rowModifier.padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Surface(
            shape = RoundedCornerShape(10.dp),
            color = MaterialTheme.colorScheme.primaryContainer,
            modifier = Modifier.size(36.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
            if (!subtitle.isNullOrBlank()) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(12.dp))
            trailing()
        } else if (onClick != null) {
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 行间细分割线(缩进对齐图标右侧)。 */
@Composable
private fun RowDivider() {
    Divider(
        color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
        modifier = Modifier.padding(start = 66.dp)
    )
}

/** 水波渐变品牌 Hero:首页顶部的标志性卡片。 */
@Composable
private fun BrandHeroCard(title: String, subtitle: String) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        color = Color.Transparent
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LobsterBrandGradient)
                .padding(20.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Surface(shape = CircleShape, color = Color.White.copy(alpha = 0.22f), modifier = Modifier.size(48.dp)) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.GraphicEq, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
                    }
                }
                Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Color.White)
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.92f))
            }
        }
    }
}

/** 账户 Profile Hero:渐变卡突出邮箱、套餐与积分。 */
@Composable
private fun ProfileHeroCard(language: MobileLanguage, email: String?, plan: com.lobster.input.data.model.UserPlanInfo?) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        color = Color.Transparent
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LobsterBrandGradient)
                .padding(20.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(shape = CircleShape, color = Color.White.copy(alpha = 0.22f), modifier = Modifier.size(48.dp)) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(Icons.Default.Person, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
                        }
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            email ?: mobileText(language, "未登录", "Not signed in", "Не выполнен вход", "로그인 안 됨"),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = Color.White
                        )
                        Text(
                            plan?.let { it.planName.ifBlank { localizedPlanName(language, it.tier) } }
                                ?: mobileText(language, "加载中", "Loading", "Загрузка", "로딩 중"),
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.9f)
                        )
                    }
                }
                // 套餐积分汇总卡片：剩余/总积分 + 进度条 + 已用积分 + 重置日期 + 套餐有效期
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White.copy(alpha = 0.16f), RoundedCornerShape(12.dp))
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            mobileText(language, "剩余积分", "Credits left", "Осталось кредитов", "남은 크레딧"),
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color.White.copy(alpha = 0.92f)
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            plan?.let { "${it.creditsRemaining} / ${it.creditsTotal}" } ?: "—",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = Color.White
                        )
                    }
                    if (plan != null && plan.creditsTotal > 0) {
                        val ratio = (plan.creditsRemaining.toFloat() / plan.creditsTotal.toFloat())
                            .coerceIn(0f, 1f)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .background(Color.White.copy(alpha = 0.22f), RoundedCornerShape(3.dp))
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(ratio)
                                    .height(6.dp)
                                    .background(Color.White.copy(alpha = 0.9f), RoundedCornerShape(3.dp))
                            )
                        }
                    }
                    if (plan != null) {
                        HeroCreditInfoRow(
                            mobileText(language, "已用积分", "Used", "Использовано", "사용됨"),
                            "${plan.creditsUsed}"
                        )
                        formatServerDate(plan.creditsResetAt)?.let { reset ->
                            HeroCreditInfoRow(
                                mobileText(language, "积分重置日期", "Credits reset", "Сброс кредитов", "크레딧 초기화"),
                                reset
                            )
                        }
                        HeroCreditInfoRow(
                            mobileText(language, "套餐有效期", "Plan valid until", "Действует до", "요금제 유효기간"),
                            formatServerDate(plan.subscriptionExpiresAt ?: plan.planExpiresAt)
                                ?: mobileText(language, "永久有效", "No expiry", "Бессрочно", "무기한", "永久有效", "永久有效")
                        )
                        // 订阅态补充一行自动续费信息;未开启自动续费时不新增 UI
                        if (plan.autoRenew) {
                            HeroCreditInfoRow(
                                mobileText(language, "自动续费", "Auto-renewal", "Автопродление", "자동 갱신", "自動續費", "自動續費"),
                                formatServerDate(plan.nextRenewalAt)
                                    ?: mobileText(language, "已开启", "On", "Вкл.", "켜짐", "已開啟", "已開啟")
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(onLogout: () -> Unit, viewModel: MainViewModel = hiltViewModel()) {
    val context = LocalContext.current
    var language by remember { mutableStateOf(MobileStrings.currentLanguage(context)) }
    val navController = rememberNavController()
    val uiState by viewModel.uiState.collectAsState()
    val navItems = bottomNavItems(language)
    val historyStore = remember(context) { MobileHistoryStore(context) }
    var historyRecords by remember { mutableStateOf(historyStore.records()) }
    fun refreshHistory() {
        historyRecords = historyStore.records()
    }
    
    LaunchedEffect(Unit) {
        viewModel.refreshAll()
    }

    LaunchedEffect(uiState.checkoutUrl) {
        val checkoutUrl = uiState.checkoutUrl ?: return@LaunchedEffect
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(checkoutUrl)))
        }
        viewModel.consumeCheckoutUrl()
    }
    
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        MobileStrings.keyboardTitle(context),
                        style = MaterialTheme.typography.titleLarge
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer
                )
            )
        },
        bottomBar = {
            NavigationBar(
                containerColor = MaterialTheme.colorScheme.surface,
                tonalElevation = 3.dp
            ) {
                val navBackStackEntry by navController.currentBackStackEntryAsState()
                val currentDestination = navBackStackEntry?.destination

                navItems.forEach { item ->
                    NavigationBarItem(
                        icon = { Icon(item.icon, contentDescription = item.label) },
                        label = { Text(item.label, style = MaterialTheme.typography.labelMedium) },
                        selected = currentDestination?.hierarchy?.any { it.route == item.route } == true,
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            selectedTextColor = MaterialTheme.colorScheme.primary,
                            indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
                        ),
                        onClick = {
                            navController.navigate(item.route) {
                                popUpTo(navController.graph.findStartDestination().id) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    )
                }
            }
        }
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = "home",
            modifier = Modifier.padding(paddingValues)
        ) {
            composable("home") {
                HomeScreen(
                    language = language,
                    email = viewModel.email,
                    plan = uiState.plan,
                    error = uiState.error,
                    onRefresh = viewModel::refreshAll
                )
            }
            composable("history") {
                LaunchedEffect(Unit) { refreshHistory() }
                HistoryScreen(
                    language = language,
                    records = historyRecords,
                    onRefresh = ::refreshHistory,
                    onDelete = {
                        historyStore.delete(it)
                        refreshHistory()
                    },
                    onClearAll = {
                        historyStore.clearAll()
                        refreshHistory()
                    }
                )
            }
            composable("dictionary") {
                DictionaryScreen(
                    language = language,
                    words = uiState.hotWords,
                    isLoading = uiState.isHotWordsLoading,
                    onRefresh = viewModel::loadHotWords,
                    onAdd = viewModel::addHotWord,
                    onUpdate = viewModel::updateHotWord,
                    onDelete = viewModel::deleteHotWord,
                    onBack = { navController.popBackStack() }
                )
            }
            composable("persona") {
                PersonaScreen(
                    language = language,
                    personas = uiState.personas,
                    isLoading = uiState.isPersonasLoading,
                    onRefresh = viewModel::loadPersonas,
                    onCreate = viewModel::createPersona,
                    onUpdate = viewModel::updatePersona,
                    onActivate = viewModel::activatePersona,
                    onDeactivate = viewModel::deactivatePersonas,
                    onDelete = viewModel::deletePersona
                )
            }
            composable("account") {
                AccountScreen(
                    email = viewModel.email,
                    plan = uiState.plan,
                    language = language,
                    onLanguageChange = {
                        MobileStrings.setLanguage(context, it)
                        language = it
                        viewModel.loadPersonas()
                    },
                    onLogout = {
                        viewModel.logout()
                        onLogout()
                    },
                    onOpenDictionary = { navController.navigate("dictionary") },
                    onOpenSubscription = { navController.navigate("subscription") },
                    onOpenInvite = { navController.navigate("invite") }
                )
            }
            composable("subscription") {
                SubscriptionScreen(
                    language = language,
                    catalog = uiState.paymentCatalog,
                    plan = uiState.plan,
                    isLoading = uiState.isPaymentCatalogLoading,
                    checkoutInProgress = uiState.checkoutInProgress,
                    isCancellingRenewal = uiState.isCancellingRenewal,
                    paymentStatus = uiState.paymentStatus,
                    onRefresh = {
                        viewModel.loadPaymentCatalog()
                        viewModel.loadPlan()
                    },
                    onSubscribe = viewModel::createSubscriptionCheckout,
                    onTopup = viewModel::createCreditsTopupCheckout,
                    onCancelRenewal = viewModel::cancelSubscriptionRenewal,
                    onBack = { navController.popBackStack() }
                )
            }
            composable("invite") {
                InviteCodesScreen(
                    language = language,
                    codes = uiState.inviteCodes,
                    isLoading = uiState.isInviteCodesLoading,
                    onLoad = viewModel::loadInviteCodes,
                    onBack = { navController.popBackStack() }
                )
            }
        }
    }
}

data class BottomNavItem(
    val route: String,
    val icon: ImageVector,
    val label: String
)

fun bottomNavItems(language: MobileLanguage) = listOf(
    BottomNavItem("home", Icons.Default.Home, mobileText(language, "首页", "Home", "Главная", "홈")),
    BottomNavItem("history", Icons.Default.History, mobileText(language, "历史", "History", "История", "기록")),
    BottomNavItem("persona", Icons.Default.Person, mobileText(language, "人设", "Persona", "Персона", "페르소나", zhHant = "人設", yue = "人設")),
    BottomNavItem("account", Icons.Default.Settings, mobileText(language, "设置", "Settings", "Настройки", "설정"))
)

@Composable
fun HomeScreen(
    language: MobileLanguage,
    email: String?,
    plan: com.lobster.input.data.model.UserPlanInfo?,
    error: String?,
    onRefresh: () -> Unit
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        item {
            BrandHeroCard(
                title = mobileText(language, "纯语音输入法已就绪", "Voice input is ready", "Голосовой ввод готов", "음성 입력 준비됨"),
                subtitle = mobileText(language, "在任意输入框切换到龙虾输入法后，可以直接使用语音输入和指令处理。系统输入法启用、切换和麦克风权限请到“设置”页完成。", "Switch to Lobster in any text field to use voice input and commands. Keyboard setup and microphone permission are in Settings.", "Выберите Lobster в любом поле, чтобы использовать голосовой ввод и команды. Настройка и микрофон находятся в настройках.", "입력창에서 랍스터 입력기로 전환하면 음성 입력과 명령을 사용할 수 있습니다. 키보드와 마이크 설정은 설정에서 진행하세요.")
            )
        }

        item {
            SectionHeader(mobileText(language, "账户状态", "Account status", "Статус аккаунта", "계정 상태"))
        }

        item {
            ElevatedCard(
                modifier = Modifier.fillMaxWidth(),
                shape = LobsterCardShape,
                colors = lobsterCardColors(),
                elevation = lobsterCardElevation()
            ) {
                Column(
                    modifier = Modifier.padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(mobileText(language, "账户概览", "Overview", "Обзор", "개요"), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                        Spacer(Modifier.weight(1f))
                        IconButton(onClick = onRefresh) {
                            Icon(Icons.Default.Refresh, contentDescription = mobileText(language, "刷新", "Refresh", "Обновить", "새로고침"), tint = MaterialTheme.colorScheme.primary)
                        }
                    }
                    InfoRow(mobileText(language, "邮箱", "Email", "Почта", "이메일"), email ?: mobileText(language, "未登录", "Not signed in", "Не выполнен вход", "로그인 안 됨"))
                    InfoRow(mobileText(language, "套餐", "Plan", "Тариф", "요금제"), plan?.let { it.planName.ifBlank { localizedPlanName(language, it.tier) } } ?: mobileText(language, "加载中", "Loading", "Загрузка", "로딩 중"))
                    InfoRow(
                        mobileText(language, "积分", "Credits", "Кредиты", "크레딧"),
                        plan?.let { "${it.creditsRemaining} / ${it.creditsTotal}" } ?: mobileText(language, "加载中", "Loading", "Загрузка", "로딩 중")
                    )
                }
            }
        }

        if (!error.isNullOrBlank()) {
            item {
                AssistChip(
                    onClick = onRefresh,
                    label = { Text(error) },
                    leadingIcon = { Icon(Icons.Default.Info, contentDescription = null) },
                    shape = RoundedCornerShape(50),
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        labelColor = MaterialTheme.colorScheme.onErrorContainer,
                        leadingIconContentColor = MaterialTheme.colorScheme.error
                    ),
                    border = null
                )
            }
        }
    }
}

@Composable
fun HistoryScreen(
    language: MobileLanguage,
    records: List<MobileHistoryRecord>,
    onRefresh: () -> Unit,
    onDelete: (String) -> Unit,
    onClearAll: () -> Unit
) {
    val clipboard = LocalClipboardManager.current
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(mobileText(language, "历史记录", "History", "История", "기록"), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onRefresh) {
                    Icon(Icons.Default.Refresh, contentDescription = mobileText(language, "刷新", "Refresh", "Обновить", "새로고침"), tint = MaterialTheme.colorScheme.primary)
                }
                if (records.isNotEmpty()) {
                    IconButton(onClick = onClearAll) {
                        Icon(Icons.Default.DeleteSweep, contentDescription = mobileText(language, "清空", "Clear", "Очистить", "비우기"), tint = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }

        if (records.isEmpty()) {
            item {
                EmptyCard(
                    mobileText(language, "暂无历史记录", "No history yet", "Истории пока нет", "기록 없음"),
                    mobileText(language, "使用输入法完成语音输入或指令处理后，记录会显示在这里。", "Voice input and command results will appear here.", "Результаты голосового ввода и команд появятся здесь.", "음성 입력과 명령 결과가 여기에 표시됩니다.")
                )
            }
        } else {
            items(records, key = { it.id }) { record ->
                HistoryRecordCard(
                    language = language,
                    record = record,
                    onCopy = { text -> clipboard.setText(AnnotatedString(text)) },
                    onDelete = { onDelete(record.id) }
                )
            }
        }
    }
}

@Composable
fun DictionaryScreen(
    language: MobileLanguage,
    words: List<HotWordItem>,
    isLoading: Boolean,
    onRefresh: () -> Unit,
    onAdd: (String) -> Unit,
    onUpdate: (String, String) -> Unit,
    onDelete: (String) -> Unit,
    onBack: () -> Unit
) {
    var newWord by remember { mutableStateOf("") }
    var editingId by remember { mutableStateOf<String?>(null) }
    var editingWord by remember { mutableStateOf("") }

    LaunchedEffect(Unit) { onRefresh() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.ArrowBack, contentDescription = mobileText(language, "返回", "Back", "Назад", "뒤로"), tint = MaterialTheme.colorScheme.onBackground)
            }
            Text(mobileText(language, "热词词典", "Hot words", "Словарь", "단어 사전"), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground)
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = newWord,
                onValueChange = { newWord = it },
                label = { Text(mobileText(language, "添加热词", "Add word", "Добавить слово", "단어 추가")) },
                modifier = Modifier.weight(1f),
                singleLine = true,
                shape = LobsterFieldShape
            )
            Spacer(Modifier.width(8.dp))
            FilledIconButton(
                onClick = {
                    onAdd(newWord)
                    newWord = ""
                },
                enabled = newWord.isNotBlank(),
                modifier = Modifier.size(56.dp),
                shape = LobsterButtonShape
            ) {
                Icon(Icons.Default.Add, contentDescription = mobileText(language, "新增", "Add", "Добавить", "추가"))
            }
        }

        if (isLoading) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }

        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (words.isEmpty() && !isLoading) {
                item { EmptyCard(mobileText(language, "暂无热词", "No words yet", "Слов пока нет", "단어 없음"), mobileText(language, "添加行业术语、人名、产品名后，语音识别会更稳定。", "Add terms, names, and product names to improve recognition.", "Добавьте термины, имена и продукты для лучшего распознавания.", "용어, 이름, 제품명을 추가하면 인식이 더 안정적입니다.")) }
            }
            items(words, key = { it.id }) { item ->
                HotWordRow(
                    language = language,
                    item = item,
                    isEditing = editingId == item.id,
                    editingWord = editingWord,
                    onEditingWordChange = { editingWord = it },
                    onStartEdit = {
                        editingId = item.id
                        editingWord = item.word
                    },
                    onSave = {
                        onUpdate(item.id, editingWord)
                        editingId = null
                    },
                    onCancel = { editingId = null },
                    onDelete = { onDelete(item.id) }
                )
            }
        }
    }
}

@Composable
fun PersonaScreen(
    language: MobileLanguage,
    personas: List<PersonaItem>,
    isLoading: Boolean,
    onRefresh: () -> Unit,
    onCreate: (String, String, PersonaPrompts) -> Unit,
    onUpdate: (String, String, String, PersonaPrompts) -> Unit,
    onActivate: (String) -> Unit,
    onDeactivate: () -> Unit,
    onDelete: (String) -> Unit
) {
    var showCreateDialog by remember { mutableStateOf(false) }
    var editingPersonaId by remember { mutableStateOf<String?>(null) }
    val userPersonaCount = personas.count { !it.isBuiltin }
    val editingPersona = personas.firstOrNull { it.id == editingPersonaId }

    LaunchedEffect(Unit) { onRefresh() }
    LaunchedEffect(personas) {
        if (editingPersonaId != null && editingPersona == null) {
            editingPersonaId = null
        }
    }

    if (editingPersona != null) {
        PersonaEditScreen(
            language = language,
            persona = editingPersona,
            isLoading = isLoading,
            onBack = { editingPersonaId = null },
            onSave = { name, desc, prompts ->
                onUpdate(editingPersona.id, name, desc, prompts)
                editingPersonaId = null
            }
        )
    } else {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(mobileText(language, "人设配置", "Persona setup", "Настройка персоны", "페르소나 설정", zhHant = "人設設定", yue = "人設設定"), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground)
                    Text("$userPersonaCount / $PERSONA_MAX_COUNT", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                FilledIconButton(
                    onClick = { showCreateDialog = true },
                    enabled = userPersonaCount < PERSONA_MAX_COUNT,
                    modifier = Modifier.size(48.dp),
                    shape = LobsterButtonShape
                ) {
                    Icon(Icons.Default.Add, contentDescription = mobileText(language, "新建", "New", "Создать", "새로 만들기"))
                }
            }

            if (isLoading) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (personas.isEmpty() && !isLoading) {
                    item { EmptyCard(mobileText(language, "暂无人设", "No personas yet", "Персон пока нет", "페르소나 없음", zhHant = "暫無人設", yue = "暫無人設"), mobileText(language, "创建不同场景的语音输入和指令处理提示词，启用后会影响输入法输出效果。", "Create prompts for voice input and command output.", "Создайте подсказки для голосового ввода и команд.", "음성 입력과 명령 결과용 프롬프트를 만들 수 있습니다.", zhHant = "建立不同場景的語音輸入和指令處理提示詞，啟用後會影響輸入法輸出效果。", yue = "建立唔同場景嘅語音輸入同指令處理提示詞，啟用後會影響輸入法輸出效果。")) }
                }
                items(personas, key = { it.id }) { persona ->
                    PersonaCard(
                        language = language,
                        persona = persona,
                        onOpen = { if (!persona.isBuiltin) editingPersonaId = persona.id },
                        onActivate = { onActivate(persona.id) },
                        onDeactivate = onDeactivate,
                        onDelete = { onDelete(persona.id) }
                    )
                }
            }
        }
    }

    if (showCreateDialog) {
        CreatePersonaDialog(
            language = language,
            onDismiss = { showCreateDialog = false },
            onCreate = { name, desc, prompts ->
                onCreate(name, desc, prompts)
                showCreateDialog = false
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(
    email: String?,
    plan: com.lobster.input.data.model.UserPlanInfo?,
    language: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    onLogout: () -> Unit,
    onOpenDictionary: () -> Unit,
    onOpenSubscription: () -> Unit,
    onOpenInvite: () -> Unit
) {
    val context = LocalContext.current
    val prefs = remember(context) { context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE) }
    val lifecycleOwner = LocalLifecycleOwner.current
    val statusScope = rememberCoroutineScope()
    val updateManager = remember(context) { AndroidUpdateManager(context.applicationContext) }
    var updateState by remember { mutableStateOf<AccountUpdateUiState?>(null) }
    val installedVersion = remember(updateState) { updateManager.currentInstalledVersion() }
    val inputMethodManager = remember {
        context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
    }
    fun checkUpdate() {
        updateState = AccountUpdateUiState.Checking
        statusScope.launch {
            runCatching { updateManager.checkForUpdate() }
                .onSuccess { result ->
                    updateState = when (result) {
                        AndroidUpdateCheckResult.NoUpdate -> AccountUpdateUiState.NoUpdate
                        is AndroidUpdateCheckResult.UpdateAvailable -> AccountUpdateUiState.Available(result.manifest)
                    }
                }
                .onFailure { error ->
                    updateState = AccountUpdateUiState.Error(error.message ?: mobileText(language, "检查更新失败", "Update check failed", "Не удалось проверить обновления", "업데이트 확인 실패"))
                }
        }
    }
    fun downloadAndInstall(manifest: AndroidUpdateManifest) {
        if (!updateManager.canRequestPackageInstalls()) {
            updateState = AccountUpdateUiState.PermissionRequired(manifest)
            return
        }
        updateState = AccountUpdateUiState.Downloading(manifest, progress = 0)
        statusScope.launch {
            runCatching {
                updateManager.downloadApk(manifest) { progress ->
                    statusScope.launch(Dispatchers.Main) {
                        updateState = AccountUpdateUiState.Downloading(manifest, progress)
                    }
                }
            }
                .onSuccess { apkFile ->
                    updateState = null
                    updateManager.installApk(apkFile)
                }
                .onFailure { error ->
                    updateState = AccountUpdateUiState.Error(error.message ?: mobileText(language, "下载更新失败", "Update download failed", "Не удалось скачать обновление", "업데이트 다운로드 실패"))
                }
        }
    }
    var imeCurrent by remember { mutableStateOf(isLobsterImeCurrent(context)) }
    var hasRecordAudioPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    fun refreshInputStatus() {
        imeCurrent = isLobsterImeCurrent(context)
        hasRecordAudioPermission =
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
    }
    fun refreshInputStatusSoon() {
        statusScope.launch {
            repeat(10) {
                delay(700)
                refreshInputStatus()
            }
        }
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                refreshInputStatusSoon()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(Unit) {
        refreshInputStatusSoon()
    }
    val microphonePermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasRecordAudioPermission = granted
    }
    var languageMenuExpanded by remember { mutableStateOf(false) }
    var realtimeRecognitionEnabled by remember {
        mutableStateOf(prefs.getBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, false))
    }
    // 拼音键盘:模糊音(单个总开关,默认关)+ 纠错(默认开)
    var fuzzyEnabled by remember { mutableStateOf(prefs.getBoolean(TypingPreferences.KEY_FUZZY_ZZH, false)) }
    var pinyinCorrectionEnabled by remember { mutableStateOf(prefs.getBoolean(TypingPreferences.KEY_CORRECTION, true)) }
    val showInviteCodesEnabled = plan?.showInviteCodesEnabled == true

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            ProfileHeroCard(language = language, email = email, plan = plan)
        }

        item {
            SectionHeader(mobileText(language, "账户", "Account", "Аккаунт", "계정"))
        }

        item {
            SettingsGroup {
                SettingRow(
                    icon = Icons.Default.WorkspacePremium,
                    title = mobileText(language, "订阅与套餐", "Subscription", "Подписка", "구독"),
                    subtitle = plan?.let { it.planName.ifBlank { localizedPlanName(language, it.tier) } } ?: mobileText(language, "查看套餐与积分加购", "View plans and top-up", "Тарифы и пополнение", "요금제 및 충전 보기"),
                    onClick = onOpenSubscription
                )
                if (showInviteCodesEnabled) {
                    RowDivider()
                    SettingRow(
                        icon = Icons.Default.CardGiftcard,
                        title = mobileText(language, "我的邀请码", "Invite codes", "Коды приглашения", "초대 코드"),
                        subtitle = mobileText(language, "邀请好友领取奖励", "Invite friends for rewards", "Приглашайте друзей", "친구 초대 보상"),
                        onClick = onOpenInvite
                    )
                }
            }
        }

        item {
            SectionHeader(mobileText(language, "输入法设置", "Keyboard", "Клавиатура", "키보드"))
        }

        item {
            ElevatedCard(
                modifier = Modifier.fillMaxWidth(),
                shape = LobsterCardShape,
                colors = lobsterCardColors(),
                elevation = lobsterCardElevation()
            ) {
                Column(
                    modifier = Modifier.padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(mobileText(language, "系统输入法配置", "Keyboard setup", "Настройка клавиатуры", "키보드 설정"), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                    InputStatusRow(mobileText(language, "当前输入法是龙虾输入法", "Lobster is current keyboard", "Lobster выбрана", "랍스터 입력기가 선택됨"), imeCurrent)
                    InputStatusRow(mobileText(language, "麦克风权限", "Microphone permission", "Доступ к микрофону", "마이크 권한"), hasRecordAudioPermission)
                    if (!(imeCurrent && hasRecordAudioPermission)) {
                        Text(
                            mobileText(language, "Android 需要用户手动开启和切换输入法。完成后返回本页可继续操作。", "Android requires manual keyboard setup and switching.", "Android требует вручную включить и выбрать клавиатуру.", "Android에서는 키보드를 직접 켜고 전환해야 합니다."),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (!imeCurrent) {
                            SetupStep(1, mobileText(language, "启用并切换输入法", "Enable and switch keyboard", "Включите и выберите", "키보드 켜고 전환"), mobileText(language, "先在系统输入法设置里打开龙虾输入法，再从输入法选择器切换到龙虾输入法。", "Enable Lobster in system settings, then select it from the keyboard picker.", "Включите Lobster в настройках, затем выберите ее.", "시스템 설정에서 랍스터를 켠 뒤 입력기 선택에서 전환하세요."))
                        }
                        if (!hasRecordAudioPermission) {
                            SetupStep(2, mobileText(language, "授予麦克风", "Allow microphone", "Разрешите микрофон", "마이크 허용"), mobileText(language, "语音输入需要 RECORD_AUDIO 权限，否则无法录音。", "Voice input needs microphone permission.", "Голосовой ввод требует доступ к микрофону.", "음성 입력에는 마이크 권한이 필요합니다."))
                        }
                    }
                    Button(
                        onClick = {
                            context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                            refreshInputStatusSoon()
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp),
                        shape = LobsterButtonShape
                    ) {
                        Icon(Icons.Default.Settings, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(mobileText(language, "打开输入法设置", "Open keyboard settings", "Открыть настройки", "입력기 설정 열기"))
                    }
                    OutlinedButton(
                        onClick = {
                            inputMethodManager.showInputMethodPicker()
                            refreshInputStatusSoon()
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp),
                        shape = LobsterButtonShape,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
                    ) {
                        Icon(Icons.Default.Keyboard, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(if (imeCurrent) mobileText(language, "当前已是龙虾输入法", "Lobster is current", "Lobster выбрана", "랍스터가 선택됨") else mobileText(language, "切换当前输入法", "Switch keyboard", "Сменить клавиатуру", "입력기 전환"))
                    }
                    OutlinedButton(
                        onClick = { microphonePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp),
                        enabled = !hasRecordAudioPermission,
                        shape = LobsterButtonShape,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
                    ) {
                        Icon(Icons.Default.Mic, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(if (hasRecordAudioPermission) mobileText(language, "麦克风权限已允许", "Microphone allowed", "Микрофон разрешен", "마이크 허용됨") else mobileText(language, "申请麦克风权限", "Request microphone", "Запросить микрофон", "마이크 권한 요청"))
                    }
                }
            }
        }

        item {
            SectionHeader(mobileText(language, "偏好", "Preferences", "Предпочтения", "환경설정"))
        }

        item {
            SettingsGroup {
                Box {
                    SettingRow(
                        icon = Icons.Default.Language,
                        title = mobileText(language, "语言", "Language", "Язык", "언어"),
                        subtitle = language.label,
                        onClick = { languageMenuExpanded = true },
                        trailing = {
                            Icon(Icons.Default.ArrowDropDown, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    )
                    DropdownMenu(expanded = languageMenuExpanded, onDismissRequest = { languageMenuExpanded = false }) {
                        MobileLanguage.values().forEach { item ->
                            DropdownMenuItem(text = { Text(item.label) }, onClick = {
                                languageMenuExpanded = false
                                onLanguageChange(item)
                            })
                        }
                    }
                }
                RowDivider()
                SettingRow(
                    icon = Icons.Default.GraphicEq,
                    title = mobileText(language, "流式实时识别", "Streaming recognition", "Потоковое распознавание", "실시간 스트리밍 인식"),
                    subtitle = mobileText(
                        language,
                        "开启后输入法麦克风改为长按实时识别；关闭后点击开始、再次点击结束。",
                        "Hold the mic for realtime recognition; off means tap to start and tap to finish.",
                        "Удерживайте микрофон для распознавания; иначе нажмите для начала и завершения.",
                        "켜면 마이크를 길게 눌러 실시간 인식, 끄면 탭으로 시작·종료합니다."
                    ),
                    trailing = {
                        Switch(
                            checked = realtimeRecognitionEnabled,
                            onCheckedChange = { enabled ->
                                realtimeRecognitionEnabled = enabled
                                prefs.edit()
                                    .putBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, enabled)
                                    .apply()
                            }
                        )
                    }
                )
                RowDivider()
                SettingRow(
                    icon = Icons.Default.Book,
                    title = mobileText(language, "热词词典", "Hot words", "Словарь", "단어 사전"),
                    subtitle = mobileText(language, "添加专属词汇，提升识别准确度", "Add custom words to improve accuracy", "Добавьте слова для точности", "정확도 향상을 위한 단어 추가"),
                    onClick = onOpenDictionary
                )
            }
        }

        item {
            SectionHeader(mobileText(language, "拼音键盘", "Pinyin keyboard", "Клавиатура пиньинь", "병음 키보드"))
        }

        item {
            SettingsGroup {
                SettingRow(
                    icon = Icons.Default.Tune,
                    title = mobileText(language, "模糊音", "Fuzzy pinyin", "Нечёткий пиньинь", "퍼지 병음"),
                    subtitle = mobileText(language, "平翘舌(z/zh)、前后鼻音(an/ang)、l/n 不分时开启;发音标准建议保持关闭", "For accents that merge z/zh, an/ang, l/n. Keep off if you type accurately.", "Для акцентов z/zh, an/ang, l/n.", "z/zh, an/ang, l/n 구분 안 될 때"),
                    trailing = {
                        Switch(checked = fuzzyEnabled, onCheckedChange = { on ->
                            fuzzyEnabled = on
                            prefs.edit()
                                .putBoolean(TypingPreferences.KEY_FUZZY_ZZH, on)
                                .putBoolean(TypingPreferences.KEY_FUZZY_CCH, on)
                                .putBoolean(TypingPreferences.KEY_FUZZY_SSH, on)
                                .putBoolean(TypingPreferences.KEY_FUZZY_ANANG, on)
                                .putBoolean(TypingPreferences.KEY_FUZZY_ENENG, on)
                                .putBoolean(TypingPreferences.KEY_FUZZY_INING, on)
                                .putBoolean(TypingPreferences.KEY_FUZZY_LN, on)
                                .apply()
                        })
                    }
                )
                RowDivider()
                SettingRow(
                    icon = Icons.Default.Spellcheck,
                    title = mobileText(language, "拼音纠错", "Typo correction", "Исправление опечаток", "오타 교정"),
                    subtitle = mobileText(language, "拼错字母时智能纠正(建议保持开启)", "Auto-fix typos (recommended on)", "Автоисправление опечаток", "오타 자동 교정"),
                    trailing = {
                        Switch(checked = pinyinCorrectionEnabled, onCheckedChange = { on ->
                            pinyinCorrectionEnabled = on
                            prefs.edit().putBoolean(TypingPreferences.KEY_CORRECTION, on).apply()
                        })
                    }
                )
            }
        }

        item {
            SectionHeader(mobileText(language, "关于", "About", "О приложении", "정보"))
        }

        item {
            SettingsGroup {
                // 环境徽章:由当前激活环境常量(BuildConfig.ENV_NAME)派生,禁止写死
                // preview(内测环境)-> 内测版;uat(公测环境)-> 正式版
                val envBadge = when (BuildConfig.ENV_NAME) {
                    "preview" -> mobileText(
                        language, "内测版", "Beta", "Бета", "베타",
                        zhHant = "內測版", yue = "內測版"
                    )
                    else -> mobileText(
                        language, "正式版", "Official", "Релиз", "정식판"
                    )
                }
                SettingRow(
                    icon = Icons.Default.SystemUpdate,
                    title = mobileText(language, "检查更新", "Check for updates", "Проверить обновления", "업데이트 확인"),
                    subtitle = mobileText(
                        language,
                        "当前版本 ${installedVersion.versionName} (${installedVersion.versionCode})",
                        "Current ${installedVersion.versionName} (${installedVersion.versionCode})",
                        "Версия ${installedVersion.versionName} (${installedVersion.versionCode})",
                        "현재 ${installedVersion.versionName} (${installedVersion.versionCode})"
                    ),
                    enabled = updateState !is AccountUpdateUiState.Checking &&
                        updateState !is AccountUpdateUiState.Downloading,
                    onClick = ::checkUpdate,
                    trailing = {
                        Surface(
                            shape = LobsterChipShape,
                            color = MaterialTheme.colorScheme.primaryContainer
                        ) {
                            Text(
                                text = envBadge,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                            )
                        }
                    }
                )
            }
        }

        item {
            OutlinedButton(
                onClick = onLogout,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                shape = LobsterButtonShape,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.5f))
            ) {
                Icon(Icons.Default.ExitToApp, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(mobileText(language, "退出登录", "Sign out", "Выйти", "로그아웃"))
            }
        }
    }

    updateState?.let { state ->
        AndroidUpdateDialog(
            language = language,
            state = state,
            currentVersion = updateManager.currentInstalledVersion(),
            onDismiss = { updateState = null },
            onInstall = ::downloadAndInstall,
            onOpenInstallPermission = {
                updateManager.openInstallPermissionSettings()
                updateState = AccountUpdateUiState.Available(it)
            }
        )
    }
}

private sealed interface AccountUpdateUiState {
    data object Checking : AccountUpdateUiState
    data object NoUpdate : AccountUpdateUiState
    data class Available(val manifest: AndroidUpdateManifest) : AccountUpdateUiState
    data class PermissionRequired(val manifest: AndroidUpdateManifest) : AccountUpdateUiState
    data class Downloading(val manifest: AndroidUpdateManifest, val progress: Int?) : AccountUpdateUiState
    data class Error(val message: String) : AccountUpdateUiState
}

@Composable
private fun AndroidUpdateDialog(
    language: MobileLanguage,
    state: AccountUpdateUiState,
    currentVersion: AndroidInstalledVersion,
    onDismiss: () -> Unit,
    onInstall: (AndroidUpdateManifest) -> Unit,
    onOpenInstallPermission: (AndroidUpdateManifest) -> Unit
) {
    val title = when (state) {
        AccountUpdateUiState.Checking -> mobileText(language, "正在检查更新", "Checking for updates", "Проверка обновлений", "업데이트 확인 중")
        AccountUpdateUiState.NoUpdate -> mobileText(language, "当前已是最新版本", "You're up to date", "Установлена последняя версия", "최신 버전입니다")
        is AccountUpdateUiState.Available -> mobileText(language, "发现新版本", "Update available", "Доступно обновление", "업데이트 가능")
        is AccountUpdateUiState.PermissionRequired -> mobileText(language, "需要安装权限", "Install permission needed", "Нужно разрешение на установку", "설치 권한 필요")
        is AccountUpdateUiState.Downloading -> mobileText(language, "正在下载更新", "Downloading update", "Скачивание обновления", "업데이트 다운로드 중")
        is AccountUpdateUiState.Error -> mobileText(language, "更新失败", "Update failed", "Ошибка обновления", "업데이트 실패")
    }
    AlertDialog(
        onDismissRequest = {
            if (state !is AccountUpdateUiState.Checking && state !is AccountUpdateUiState.Downloading) {
                onDismiss()
            }
        },
        shape = RoundedCornerShape(20.dp),
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text(title, style = MaterialTheme.typography.titleLarge) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when (state) {
                    AccountUpdateUiState.Checking -> {
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        Text(mobileText(language, "正在读取 Android 更新源。", "Reading the Android update feed.", "Читаем источник обновлений Android.", "Android 업데이트 정보를 읽는 중입니다."))
                    }
                    AccountUpdateUiState.NoUpdate -> Text(
                        mobileText(
                            language,
                            "当前版本 ${currentVersion.versionName} (${currentVersion.versionCode}) 无需更新。",
                            "Version ${currentVersion.versionName} (${currentVersion.versionCode}) is current.",
                            "Версия ${currentVersion.versionName} (${currentVersion.versionCode}) актуальна.",
                            "버전 ${currentVersion.versionName} (${currentVersion.versionCode})는 최신입니다."
                        )
                    )
                    is AccountUpdateUiState.Available -> {
                        Text(
                            mobileText(
                                language,
                                "新版本 ${state.manifest.versionName} (${state.manifest.versionCode}) 可安装。",
                                "Version ${state.manifest.versionName} (${state.manifest.versionCode}) is ready to install.",
                                "Версия ${state.manifest.versionName} (${state.manifest.versionCode}) готова к установке.",
                                "버전 ${state.manifest.versionName} (${state.manifest.versionCode})를 설치할 수 있습니다."
                            )
                        )
                        state.manifest.releaseNotes?.takeIf { it.isNotBlank() }?.let {
                            Text(it, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    is AccountUpdateUiState.PermissionRequired -> Text(
                        mobileText(
                            language,
                            "Android 需要先允许本应用安装更新包。授权后返回本页，再点击下载并安装。",
                            "Android needs permission for this app to install update packages. Return here after allowing it.",
                            "Android требует разрешение на установку пакетов. Вернитесь сюда после разрешения.",
                            "Android에서 이 앱의 업데이트 패키지 설치 권한이 필요합니다. 허용 후 돌아오세요."
                        )
                    )
                    is AccountUpdateUiState.Downloading -> {
                        if (state.progress != null) {
                            LinearProgressIndicator(
                                progress = state.progress / 100f,
                                modifier = Modifier.fillMaxWidth()
                            )
                        } else {
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        }
                        Text(
                            if (state.progress != null) {
                                mobileText(
                                    language,
                                    "正在下载 ${state.manifest.versionName}：${state.progress}%，完成后会拉起系统安装器。",
                                    "Downloading ${state.manifest.versionName}: ${state.progress}%. The system installer will open next.",
                                    "Скачиваем ${state.manifest.versionName}: ${state.progress}%. Затем откроется системный установщик.",
                                    "${state.manifest.versionName} 다운로드 중: ${state.progress}%. 완료 후 시스템 설치 화면이 열립니다."
                                )
                            } else {
                                mobileText(
                                    language,
                                    "正在下载 ${state.manifest.versionName}，完成后会拉起系统安装器。",
                                    "Downloading ${state.manifest.versionName}. The system installer will open next.",
                                    "Скачиваем ${state.manifest.versionName}. Затем откроется системный установщик.",
                                    "${state.manifest.versionName} 다운로드 중입니다. 완료 후 시스템 설치 화면이 열립니다."
                                )
                            }
                        )
                    }
                    is AccountUpdateUiState.Error -> Text(state.message)
                }
            }
        },
        confirmButton = {
            when (state) {
                is AccountUpdateUiState.Available -> Button(onClick = { onInstall(state.manifest) }, shape = LobsterButtonShape) {
                    Text(mobileText(language, "下载并安装", "Download and install", "Скачать и установить", "다운로드 및 설치"))
                }
                is AccountUpdateUiState.PermissionRequired -> Button(onClick = { onOpenInstallPermission(state.manifest) }, shape = LobsterButtonShape) {
                    Text(mobileText(language, "去授权", "Allow", "Разрешить", "허용하기"))
                }
                AccountUpdateUiState.Checking,
                is AccountUpdateUiState.Downloading -> Unit
                AccountUpdateUiState.NoUpdate,
                is AccountUpdateUiState.Error -> TextButton(onClick = onDismiss) {
                    Text(mobileText(language, "知道了", "OK", "ОК", "확인"))
                }
            }
        },
        dismissButton = {
            if (state !is AccountUpdateUiState.Checking && state !is AccountUpdateUiState.Downloading) {
                TextButton(onClick = onDismiss) {
                    Text(mobileText(language, "取消", "Cancel", "Отмена", "취소"))
                }
            }
        }
    )
}

/** 订阅子页面:从设置页「订阅与套餐」进入,承载完整套餐目录与积分加购。 */
@Composable
fun SubscriptionScreen(
    language: MobileLanguage,
    catalog: PaymentCatalogResponse?,
    plan: com.lobster.input.data.model.UserPlanInfo?,
    isLoading: Boolean,
    checkoutInProgress: String?,
    isCancellingRenewal: Boolean,
    paymentStatus: String?,
    onRefresh: () -> Unit,
    onSubscribe: (PaymentSubscriptionPlan, PaymentBillingOption) -> Unit,
    onTopup: () -> Unit,
    onCancelRenewal: () -> Unit,
    onBack: () -> Unit
) {
    LaunchedEffect(Unit) { onRefresh() }
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = mobileText(language, "返回", "Back", "Назад", "뒤로"), tint = MaterialTheme.colorScheme.onBackground)
                }
                Text(mobileText(language, "订阅与套餐", "Subscription", "Подписка", "구독"), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground)
            }
        }
        item {
            PaymentSubscriptionCard(
                language = language,
                catalog = catalog,
                plan = plan,
                isLoading = isLoading,
                checkoutInProgress = checkoutInProgress,
                isCancellingRenewal = isCancellingRenewal,
                paymentStatus = paymentStatus,
                onRefresh = onRefresh,
                onSubscribe = onSubscribe,
                onTopup = onTopup,
                onCancelRenewal = onCancelRenewal
            )
        }
    }
}

/** 邀请码子页面:从设置页「我的邀请码」进入。 */
@Composable
fun InviteCodesScreen(
    language: MobileLanguage,
    codes: List<com.lobster.input.data.model.InviteCodeItem>,
    isLoading: Boolean,
    onLoad: () -> Unit,
    onBack: () -> Unit
) {
    val clipboard = LocalClipboardManager.current
    LaunchedEffect(Unit) { onLoad() }
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = mobileText(language, "返回", "Back", "Назад", "뒤로"), tint = MaterialTheme.colorScheme.onBackground)
                }
                Text(mobileText(language, "我的邀请码", "Invite codes", "Коды приглашения", "초대 코드"), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground)
            }
        }
        if (isLoading) {
            item { LinearProgressIndicator(modifier = Modifier.fillMaxWidth()) }
        }
        if (codes.isEmpty() && !isLoading) {
            item {
                EmptyCard(
                    mobileText(language, "暂无邀请码", "No invite codes", "Нет кодов", "초대 코드 없음"),
                    mobileText(language, "邀请码会在这里显示，可复制分享给好友。", "Your invite codes appear here to share with friends.", "Здесь появятся коды приглашения для друзей.", "초대 코드가 여기에 표시되어 친구에게 공유할 수 있습니다.")
                )
            }
        }
        items(codes) { code ->
            ElevatedCard(
                modifier = Modifier.fillMaxWidth(),
                shape = LobsterCardShape,
                colors = lobsterCardColors(),
                elevation = lobsterCardElevation()
            ) {
                Row(
                    modifier = Modifier.padding(start = 16.dp, top = 6.dp, bottom = 6.dp, end = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(code.code, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                        Text(
                            if (code.isUsed) mobileText(language, "已使用", "Used", "Использован", "사용됨") else mobileText(language, "未使用", "Unused", "Не использован", "미사용"),
                            style = MaterialTheme.typography.bodySmall,
                            color = if (code.isUsed) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary
                        )
                    }
                    TextButton(onClick = { clipboard.setText(AnnotatedString(code.code)) }) {
                        Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(mobileText(language, "复制", "Copy", "Копировать", "복사"))
                    }
                }
            }
        }
    }
}

@Composable
private fun PaymentSubscriptionCard(
    language: MobileLanguage,
    catalog: PaymentCatalogResponse?,
    plan: com.lobster.input.data.model.UserPlanInfo?,
    isLoading: Boolean,
    checkoutInProgress: String?,
    isCancellingRenewal: Boolean,
    paymentStatus: String?,
    onRefresh: () -> Unit,
    onSubscribe: (PaymentSubscriptionPlan, PaymentBillingOption) -> Unit,
    onTopup: () -> Unit,
    onCancelRenewal: () -> Unit
) {
    val selectedCycles = remember(catalog?.subscriptions) { mutableStateMapOf<String, String>() }

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(mobileText(language, "订阅与充值", "Subscription", "Подписка", "구독"), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                    Text(
                        mobileText(
                            language,
                            "购买后会打开安全支付页面，支付完成后回到 App 刷新状态。",
                            "A secure payment page opens in your browser. Return and refresh after payment.",
                            "Откроется безопасная страница оплаты. После оплаты вернитесь и обновите.",
                            "브라우저에서 안전한 결제 페이지가 열립니다. 결제 후 돌아와 새로고침하세요."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                IconButton(onClick = onRefresh, enabled = !isLoading) {
                    if (isLoading) {
                        CircularProgressIndicator(modifier = Modifier.width(22.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Default.Refresh, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    }
                }
            }

            paymentStatus?.takeIf { it.isNotBlank() }?.let {
                AssistChip(
                    onClick = {},
                    label = { Text(it) },
                    shape = LobsterChipShape,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
                        labelColor = MaterialTheme.colorScheme.onSecondaryContainer
                    ),
                    border = null
                )
            }

            when {
                catalog == null && isLoading -> LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                catalog == null -> {
                    Text(
                        mobileText(language, "订阅信息暂不可用", "Subscription is unavailable", "Подписка недоступна", "구독 정보를 사용할 수 없습니다"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedButton(
                        onClick = onRefresh,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp),
                        shape = LobsterButtonShape,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
                    ) {
                        Text(mobileText(language, "重新加载", "Reload", "Загрузить снова", "다시 불러오기"))
                    }
                }
                !catalog.subscriptionModule.enabled -> Text(
                    mobileText(language, "订阅功能暂未开放", "Subscription is not available", "Подписка пока недоступна", "구독 기능이 아직 열려 있지 않습니다"),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                else -> {
                    PaymentCurrentPlanSummary(language, catalog)
                    AutoRenewSection(
                        language = language,
                        plan = plan,
                        isCancelling = isCancellingRenewal,
                        onCancelRenewal = onCancelRenewal
                    )
                    if (catalog.creditsTopup.available) {
                        PaymentTopupRow(
                            language = language,
                            topup = catalog.creditsTopup,
                            loading = checkoutInProgress == "topup",
                            enabled = checkoutInProgress == null,
                            onTopup = onTopup
                        )
                        Divider()
                    }
                    catalog.subscriptions.sortedBy { it.rank }.forEach { subscription ->
                        val options = subscription.billingOptions.sortedWith(compareBy { billingCycleRank(it.cycle) })
                        // 默认账期:月付可购(或旧后端未提供判定)时维持月付优先,否则优先第一个可购账期
                        val selectedCycle = selectedCycles[subscription.planCode]
                            ?: options.firstOrNull { it.cycle == "monthly" && it.purchasable != false }?.cycle
                            ?: options.firstOrNull { it.purchasable == true }?.cycle
                            ?: options.firstOrNull { it.cycle == "monthly" }?.cycle
                            ?: options.firstOrNull()?.cycle
                            ?: ""
                        if (selectedCycle.isNotBlank()) {
                            selectedCycles[subscription.planCode] = selectedCycle
                        }
                        val selectedOption = options.firstOrNull { it.cycle == selectedCycle } ?: options.firstOrNull()
                        PaymentPlanRow(
                            language = language,
                            catalog = catalog,
                            plan = subscription,
                            options = options,
                            selectedOption = selectedOption,
                            selectedCycle = selectedCycle,
                            checkoutInProgress = checkoutInProgress,
                            onCycleChange = { selectedCycles[subscription.planCode] = it },
                            onSubscribe = onSubscribe
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun PaymentCurrentPlanSummary(language: MobileLanguage, catalog: PaymentCatalogResponse) {
    val current = catalog.currentPlan
    val currentName = current.planName.ifBlank {
        catalog.subscriptions.firstOrNull { it.planCode == current.planCode }?.name
            ?: localizedPlanName(language, current.planCode)
    }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        shape = LobsterCardShape
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(mobileText(language, "当前套餐", "Current plan", "Текущий тариф", "현재 요금제"), style = MaterialTheme.typography.labelMedium)
                Text(currentName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
            Text(
                "${current.planCreditsRemaining} / ${current.planCreditsTotal}",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}

/**
 * 当前套餐区域的自动续费状态,三态渲染(文案不含任何渠道字样):
 * 1. 开启且可取消 → 「将于 {日期} 自动续费」+「取消自动续费」入口(带确认对话框);
 * 2. 开启但不可在本端取消 → 仅一行「自动续费已开启,可在订阅设备的应用商店中管理」;
 * 3. 未开启 → 不渲染任何内容。
 */
@Composable
private fun AutoRenewSection(
    language: MobileLanguage,
    plan: com.lobster.input.data.model.UserPlanInfo?,
    isCancelling: Boolean,
    onCancelRenewal: () -> Unit
) {
    if (plan == null || !plan.autoRenew) return
    var showConfirm by remember { mutableStateOf(false) }
    val renewalDate = formatServerDate(plan.nextRenewalAt)
    // 取消后套餐可继续使用的截止日:优先下次续费日,兜底套餐到期日
    val effectiveDate = renewalDate
        ?: formatServerDate(plan.subscriptionExpiresAt ?: plan.planExpiresAt)

    if (plan.renewalCancellable) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                renewalDate?.let {
                    mobileText(language, "将于 $it 自动续费", "Auto-renews on $it", "Автопродление $it", "$it 자동 갱신", "將於 $it 自動續費", "將於 $it 自動續費")
                } ?: mobileText(language, "自动续费已开启", "Auto-renewal is on", "Автопродление включено", "자동 갱신 켜짐", "自動續費已開啟", "自動續費已開啟"),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            TextButton(onClick = { showConfirm = true }, enabled = !isCancelling) {
                if (isCancelling) {
                    CircularProgressIndicator(modifier = Modifier.width(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(mobileText(language, "取消自动续费", "Cancel auto-renewal", "Отключить автопродление", "자동 갱신 해지", "取消自動續費", "取消自動續費"))
                }
            }
        }
    } else {
        Text(
            mobileText(
                language,
                "自动续费已开启，可在订阅设备的应用商店中管理",
                "Auto-renewal is on. Manage it in the app store on the device where you subscribed.",
                "Автопродление включено. Управляйте им в магазине приложений на устройстве, где оформлена подписка.",
                "자동 갱신이 켜져 있습니다. 구독한 기기의 앱 스토어에서 관리하세요.",
                "自動續費已開啟，可在訂閱裝置的應用商店中管理",
                "自動續費已開啟，可以喺訂閱嗰部裝置嘅應用商店入面管理"
            ),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }

    if (showConfirm) {
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = {
                Text(mobileText(language, "取消自动续费", "Cancel auto-renewal", "Отключить автопродление", "자동 갱신 해지", "取消自動續費", "取消自動續費"))
            },
            text = {
                Text(
                    effectiveDate?.let {
                        mobileText(
                            language,
                            "取消后套餐仍可使用至 $it，到期后不再自动扣费。",
                            "Your plan stays active until $it. You won't be charged after it ends.",
                            "Тариф действует до $it. После окончания списаний не будет.",
                            "요금제는 $it 까지 이용할 수 있으며, 만료 후 더 이상 결제되지 않습니다.",
                            "取消後套餐仍可使用至 $it，到期後不再自動扣費。",
                            "取消之後套餐仍然可以用到 $it，到期之後唔會再自動扣費。"
                        )
                    } ?: mobileText(
                        language,
                        "取消后套餐仍可使用至到期日，到期后不再自动扣费。",
                        "Your plan stays active until the end of the current period. You won't be charged after it ends.",
                        "Тариф действует до конца текущего периода. После окончания списаний не будет.",
                        "요금제는 현재 이용 기간이 끝날 때까지 유지되며, 만료 후 더 이상 결제되지 않습니다.",
                        "取消後套餐仍可使用至到期日，到期後不再自動扣費。",
                        "取消之後套餐仍然可以用到到期日，到期之後唔會再自動扣費。"
                    )
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showConfirm = false
                    onCancelRenewal()
                }) {
                    Text(mobileText(language, "确认取消", "Confirm", "Подтвердить", "확인", "確認取消", "確認取消"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirm = false }) {
                    Text(mobileText(language, "暂不", "Not now", "Позже", "나중에", "暫不", "暫不"))
                }
            }
        )
    }
}

@Composable
private fun PaymentTopupRow(
    language: MobileLanguage,
    topup: PaymentCreditsTopup,
    loading: Boolean,
    enabled: Boolean,
    onTopup: () -> Unit
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text(mobileText(language, "积分加购", "Credit top-up", "Пополнение кредитов", "크레딧 충전"), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurface)
            Text(
                topup.amount?.let { paymentCreditsText(language, it) }.orEmpty(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Button(onClick = onTopup, enabled = enabled, shape = LobsterButtonShape) {
            if (loading) {
                CircularProgressIndicator(modifier = Modifier.width(18.dp), strokeWidth = 2.dp)
            } else {
                Text(topup.priceCents?.let { priceText(it, topup.currency) } ?: mobileText(language, "购买", "Buy", "Купить", "구매"))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PaymentPlanRow(
    language: MobileLanguage,
    catalog: PaymentCatalogResponse,
    plan: PaymentSubscriptionPlan,
    options: List<PaymentBillingOption>,
    selectedOption: PaymentBillingOption?,
    selectedCycle: String,
    checkoutInProgress: String?,
    onCycleChange: (String) -> Unit,
    onSubscribe: (PaymentSubscriptionPlan, PaymentBillingOption) -> Unit
) {
    // —— 套餐级判定(旧后端兜底,选项未携带 purchasable 字段时使用)——
    val currentRank = catalog.subscriptions.firstOrNull { it.planCode == catalog.currentPlan.planCode }?.rank
    val isCurrent = catalog.currentPlan.paid && catalog.currentPlan.planCode == plan.planCode
    val isLowerTier = catalog.currentPlan.paid && currentRank != null && plan.rank <= currentRank && !isCurrent
    val loadingKey = selectedOption?.let { "${plan.planCode}:${it.cycle}" }

    // —— 选项级判定(新后端):服务端权威下发 purchasable / blocked_reason ——
    val purchasableFlag = selectedOption?.purchasable
    val optionBlocked: Boolean       // 选中账期是否不可购
    val isUpgrade: Boolean           // 是否以「补差价升级」形态购买
    val blockedAsCurrent: Boolean    // 不可购原因是否为重复购买(展示「当前套餐」)
    when {
        // 未付费用户全部可购,保持现状
        !catalog.currentPlan.paid -> {
            optionBlocked = false
            isUpgrade = false
            blockedAsCurrent = false
        }
        // 新后端:按选项级 purchasable 判定
        selectedOption != null && purchasableFlag != null -> {
            optionBlocked = !purchasableFlag
            isUpgrade = purchasableFlag && (selectedOption.isProratedUpgrade || isCurrent)
            blockedAsCurrent = !purchasableFlag && selectedOption.blockedReason == "duplicate_purchase"
        }
        // 旧后端兜底:维持原套餐级逻辑
        else -> {
            optionBlocked = isCurrent || isLowerTier
            isUpgrade = false
            blockedAsCurrent = isCurrent
        }
    }
    val canSubscribe = selectedOption != null && !optionBlocked && checkoutInProgress == null
    // 整卡置灰:仅当所有账期选项均被服务端判定为不可购
    val allOptionsBlocked = catalog.currentPlan.paid && options.isNotEmpty() && options.all { it.purchasable == false }

    Column(
        modifier = if (allOptionsBlocked) Modifier.alpha(0.5f) else Modifier,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(plan.name.ifBlank { localizedPlanName(language, plan.planCode) }, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                Text(
                    paymentCreditsText(language, plan.credits),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                selectedOption?.let {
                    // 价格展示使用实际应付金额(补差价升级时为差价)
                    Text(priceText(it.effectivePriceCents, it.currency), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                    if (it.isProratedUpgrade && !optionBlocked) {
                        Text(
                            mobileText(language, "已抵扣未使用部分", "Unused portion credited", "Неиспользованная часть зачтена", "미사용분 차감 적용", zhHant = "已抵扣未使用部分", yue = "已抵扣未使用部分"),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    Text(billingCycleTitle(language, it.cycle), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        if (options.size > 1) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                options.forEach { option ->
                    FilterChip(
                        selected = option.cycle == selectedCycle,
                        onClick = { onCycleChange(option.cycle) },
                        label = { Text(billingCycleTitle(language, option.cycle)) },
                        enabled = checkoutInProgress == null,
                        shape = LobsterChipShape,
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    )
                }
            }
        }

        Button(
            onClick = { selectedOption?.let { onSubscribe(plan, it) } },
            enabled = canSubscribe,
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp),
            shape = LobsterButtonShape
        ) {
            if (checkoutInProgress == loadingKey) {
                CircularProgressIndicator(modifier = Modifier.width(18.dp), strokeWidth = 2.dp)
            } else {
                Text(
                    when {
                        isUpgrade -> mobileText(language, "升级", "Upgrade", "Обновить", "업그레이드", zhHant = "升級", yue = "升級")
                        blockedAsCurrent -> mobileText(language, "当前套餐", "Current plan", "Текущий тариф", "현재 요금제")
                        optionBlocked -> mobileText(language, "暂不支持降级", "Downgrade unavailable", "Понижение недоступно", "다운그레이드 불가")
                        else -> mobileText(language, "订阅", "Subscribe", "Подписаться", "구독")
                    }
                )
            }
        }
        Divider()
    }
}

@Composable
private fun HistoryRecordCard(
    language: MobileLanguage,
    record: MobileHistoryRecord,
    onCopy: (String) -> Unit,
    onDelete: () -> Unit
) {
    val output = record.result?.takeIf { it.isNotBlank() } ?: record.transcript.orEmpty()
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = if (record.status == MobileHistoryStatus.SUCCESS) Icons.Default.CheckCircle else Icons.Default.Error,
                    contentDescription = null,
                    tint = if (record.status == MobileHistoryStatus.SUCCESS) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(8.dp))
                AssistChip(
                    onClick = {},
                    label = { Text(operationText(language, record.operation)) },
                    shape = LobsterChipShape,
                    colors = AssistChipDefaults.assistChipColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant,
                        labelColor = MaterialTheme.colorScheme.onSurfaceVariant
                    ),
                    border = null
                )
                Spacer(Modifier.weight(1f))
                Text(
                    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(record.createdAt)),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (!record.selectedText.isNullOrBlank()) {
                Text(
                    "${mobileText(language, "原文", "Original", "Оригинал", "원문")}：${record.selectedText}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (output.isNotBlank()) {
                Text(output, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
            }

            if (!record.errorMessage.isNullOrBlank()) {
                Text(record.errorMessage, color = MaterialTheme.colorScheme.error)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { onCopy(output) }, enabled = output.isNotBlank()) {
                    Text(mobileText(language, "复制", "Copy", "Копировать", "복사"))
                }
                TextButton(onClick = onDelete) {
                    Text(mobileText(language, "删除", "Delete", "Удалить", "삭제"))
                }
            }
        }
    }
}

@Composable
private fun HotWordRow(
    language: MobileLanguage,
    item: HotWordItem,
    isEditing: Boolean,
    editingWord: String,
    onEditingWordChange: (String) -> Unit,
    onStartEdit: () -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        if (isEditing) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = editingWord,
                    onValueChange = onEditingWordChange,
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    shape = LobsterFieldShape
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onSave, enabled = editingWord.isNotBlank(), shape = LobsterButtonShape) { Text(mobileText(language, "保存", "Save", "Сохранить", "저장")) }
                    TextButton(onClick = onCancel) { Text(mobileText(language, "取消", "Cancel", "Отмена", "취소")) }
                }
            }
        } else {
            Row(
                modifier = Modifier.padding(start = 16.dp, top = 6.dp, bottom = 6.dp, end = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(item.word, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
                TextButton(onClick = onStartEdit) { Text(mobileText(language, "编辑", "Edit", "Править", "편집")) }
                IconButton(onClick = onDelete) {
                    Icon(Icons.Default.Delete, contentDescription = mobileText(language, "删除", "Delete", "Удалить", "삭제"), tint = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun PersonaCard(
    language: MobileLanguage,
    persona: PersonaItem,
    onOpen: () -> Unit,
    onActivate: () -> Unit,
    onDeactivate: () -> Unit,
    onDelete: () -> Unit
) {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !persona.isBuiltin, onClick = onOpen),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(persona.name, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                    if (!persona.description.isNullOrBlank()) {
                        Text(persona.description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (persona.isActive) {
                    AssistChip(
                        onClick = {},
                        label = { Text(mobileText(language, "使用中", "Active", "Активна", "사용 중", zhHant = "使用中", yue = "使用中")) },
                        leadingIcon = { Icon(Icons.Default.CheckCircle, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        shape = LobsterChipShape,
                        colors = AssistChipDefaults.assistChipColors(
                            containerColor = MaterialTheme.colorScheme.primaryContainer,
                            labelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            leadingIconContentColor = MaterialTheme.colorScheme.primary
                        ),
                        border = null
                    )
                }
            }
            if (!persona.isBuiltin) {
                Text(
                    "${mobileText(language, "语音输入", "Voice input", "Голосовой ввод", "음성 입력", zhHant = "語音輸入", yue = "語音輸入")}:${enabledText(language, persona.prompts.transcribeEnabled)}  ${mobileText(language, "指令", "Command", "Команда", "명령", zhHant = "指令", yue = "指令")}:${enabledText(language, persona.prompts.rewriteEnabled)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (persona.isActive) {
                    FilledTonalButton(onClick = onDeactivate, shape = LobsterButtonShape) {
                        Text(mobileText(language, "停用", "Disable", "Выключить", "끄기", zhHant = "停用", yue = "停用"))
                    }
                } else {
                    Button(onClick = onActivate, shape = LobsterButtonShape) {
                        Text(mobileText(language, "启用", "Enable", "Включить", "켜기", zhHant = "啟用", yue = "啟用"))
                    }
                }
                if (!persona.isBuiltin) {
                    OutlinedButton(onClick = onOpen, shape = LobsterButtonShape, border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) { Text(mobileText(language, "编辑", "Edit", "Править", "편집", zhHant = "編輯", yue = "編輯")) }
                    TextButton(onClick = onDelete, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(mobileText(language, "删除", "Delete", "Удалить", "삭제", zhHant = "刪除", yue = "刪除")) }
                }
            }
        }
    }
}

@Composable
private fun PersonaEditScreen(
    language: MobileLanguage,
    persona: PersonaItem,
    isLoading: Boolean,
    onBack: () -> Unit,
    onSave: (String, String, PersonaPrompts) -> Unit
) {
    var name by remember(persona.id) { mutableStateOf(persona.name) }
    var desc by remember(persona.id) { mutableStateOf(persona.description.orEmpty()) }
    var voicePrompt by remember(persona.id) { mutableStateOf(persona.prompts.transcribePrompt.orEmpty()) }
    var commandPrompt by remember(persona.id) { mutableStateOf(persona.prompts.rewritePrompt.orEmpty()) }
    var voiceEnabled by remember(persona.id) { mutableStateOf(persona.prompts.transcribeEnabled) }
    var commandEnabled by remember(persona.id) { mutableStateOf(persona.prompts.rewriteEnabled) }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = mobileText(language, "返回", "Back", "Назад", "뒤로"), tint = MaterialTheme.colorScheme.onBackground)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(mobileText(language, "编辑人设", "Edit persona", "Правка персоны", "페르소나 편집"), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground)
                    Text(mobileText(language, "仅管理安卓输入法使用的语音输入和指令提示词。", "Only Android voice input and command prompts are edited here.", "Здесь меняются только подсказки Android для ввода и команд.", "Android 음성 입력과 명령 프롬프트만 수정합니다."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        if (isLoading) {
            item { LinearProgressIndicator(modifier = Modifier.fillMaxWidth()) }
        }
        item {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it.take(com.lobster.input.data.model.PERSONA_NAME_MAX_LENGTH) },
                label = { Text(mobileText(language, "名称", "Name", "Имя", "이름")) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                shape = LobsterFieldShape
            )
        }
        item {
            OutlinedTextField(
                value = desc,
                onValueChange = { desc = it.take(com.lobster.input.data.model.PERSONA_DESC_MAX_LENGTH) },
                label = { Text(mobileText(language, "描述", "Description", "Описание", "설명")) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                shape = LobsterFieldShape
            )
        }
        item {
            PersonaPromptEditor(
                language = language,
                title = mobileText(language, "语音输入提示词", "Voice input prompt", "Промпт голосового ввода", "음성 입력 프롬프트"),
                checked = voiceEnabled,
                enabled = voicePrompt.isNotBlank(),
                prompt = voicePrompt,
                onCheckedChange = { voiceEnabled = it && voicePrompt.isNotBlank() },
                onPromptChange = {
                    voicePrompt = it.take(PERSONA_PROMPT_MAX_LENGTH)
                    if (voicePrompt.isBlank()) voiceEnabled = false
                }
            )
        }
        item {
            PersonaPromptEditor(
                language = language,
                title = mobileText(language, "指令提示词", "Command prompt", "Промпт команды", "명령 프롬프트"),
                checked = commandEnabled,
                enabled = commandPrompt.isNotBlank(),
                prompt = commandPrompt,
                onCheckedChange = { commandEnabled = it && commandPrompt.isNotBlank() },
                onPromptChange = {
                    commandPrompt = it.take(PERSONA_PROMPT_MAX_LENGTH)
                    if (commandPrompt.isBlank()) commandEnabled = false
                }
            )
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = onBack,
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    shape = LobsterButtonShape,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
                ) {
                    Text(mobileText(language, "取消", "Cancel", "Отмена", "취소"))
                }
                Button(
                    onClick = {
                        onSave(
                            name,
                            desc,
                            persona.prompts.copy(
                                transcribePrompt = voicePrompt.ifBlank { null },
                                transcribeEnabled = voiceEnabled && voicePrompt.isNotBlank(),
                                rewritePrompt = commandPrompt.ifBlank { null },
                                rewriteEnabled = commandEnabled && commandPrompt.isNotBlank()
                            )
                        )
                    },
                    enabled = name.isNotBlank(),
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    shape = LobsterButtonShape
                ) {
                    Text(mobileText(language, "保存", "Save", "Сохранить", "저장"))
                }
            }
        }
    }
}

@Composable
private fun PersonaPromptEditor(
    language: MobileLanguage,
    title: String,
    checked: Boolean,
    enabled: Boolean,
    prompt: String,
    onCheckedChange: (Boolean) -> Unit,
    onPromptChange: (String) -> Unit
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
                Switch(checked = checked && enabled, onCheckedChange = onCheckedChange, enabled = enabled)
            }
            OutlinedTextField(
                value = prompt,
                onValueChange = onPromptChange,
                modifier = Modifier.fillMaxWidth(),
                minLines = 4,
                label = { Text(mobileText(language, "提示词", "Prompt", "Промпт", "프롬프트")) },
                supportingText = { Text("${prompt.length} / $PERSONA_PROMPT_MAX_LENGTH") },
                shape = LobsterFieldShape
            )
        }
    }
}

@Composable
private fun CreatePersonaDialog(
    language: MobileLanguage,
    onDismiss: () -> Unit,
    onCreate: (String, String, PersonaPrompts) -> Unit
) {
    var name by remember { mutableStateOf("") }
    var desc by remember { mutableStateOf("") }
    var transcribePrompt by remember { mutableStateOf("") }
    var rewritePrompt by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        shape = RoundedCornerShape(20.dp),
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text(mobileText(language, "新建人设", "New persona", "Новая персона", "새 페르소나"), style = MaterialTheme.typography.titleLarge) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text(mobileText(language, "名称", "Name", "Имя", "이름")) }, shape = LobsterFieldShape)
                OutlinedTextField(value = desc, onValueChange = { desc = it }, label = { Text(mobileText(language, "描述", "Description", "Описание", "설명")) }, shape = LobsterFieldShape)
                OutlinedTextField(
                    value = transcribePrompt,
                    onValueChange = { transcribePrompt = it },
                    label = { Text(mobileText(language, "语音输入提示词", "Voice input prompt", "Промпт голосового ввода", "음성 입력 프롬프트")) },
                    minLines = 2,
                    shape = LobsterFieldShape
                )
                OutlinedTextField(
                    value = rewritePrompt,
                    onValueChange = { rewritePrompt = it },
                    label = { Text(mobileText(language, "指令提示词", "Command prompt", "Промпт команды", "명령 프롬프트")) },
                    minLines = 2,
                    shape = LobsterFieldShape
                )
            }
        },
        confirmButton = {
            Button(
                shape = LobsterButtonShape,
                onClick = {
                    onCreate(
                        name,
                        desc,
                        PersonaPrompts(
                            transcribePrompt = transcribePrompt.ifBlank { null },
                            transcribeEnabled = transcribePrompt.isNotBlank(),
                            rewritePrompt = rewritePrompt.ifBlank { null },
                            rewriteEnabled = rewritePrompt.isNotBlank()
                        )
                    )
                },
                enabled = name.isNotBlank()
            ) {
                Text(mobileText(language, "保存", "Save", "Сохранить", "저장"))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(mobileText(language, "取消", "Cancel", "Отмена", "취소")) } }
    )
}

@Composable
private fun EmptyCard(title: String, subtitle: String) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = LobsterCardShape,
        colors = lobsterCardColors(),
        elevation = lobsterCardElevation()
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SetupStep(index: Int, title: String, description: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top
    ) {
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.primaryContainer,
            modifier = Modifier.size(28.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    index.toString(),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurface)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun InputStatusRow(label: String, enabled: Boolean) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = if (enabled) Icons.Default.CheckCircle else Icons.Default.Info,
            contentDescription = null,
            tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
            modifier = Modifier.size(20.dp)
        )
        Spacer(Modifier.width(8.dp))
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
        Surface(
            shape = LobsterChipShape,
            color = if (enabled) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.errorContainer
        ) {
            Text(
                if (enabled) "OK" else "Todo",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = if (enabled) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
            )
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
    }
}

private fun enabledText(language: MobileLanguage, enabled: Boolean): String {
    return if (enabled) {
        mobileText(language, "开", "On", "Вкл", "켜짐", zhHant = "開", yue = "開")
    } else {
        mobileText(language, "关", "Off", "Выкл", "꺼짐", zhHant = "關", yue = "關")
    }
}

private fun operationText(language: MobileLanguage, operation: String): String {
    return when {
        operation == "rewrite" -> mobileText(language, "指令", "Command", "Команда", "명령", zhHant = "指令", yue = "指令")
        operation.startsWith("android_quick_") -> mobileText(language, "快捷处理", "Quick action", "Быстро", "빠른 처리")
        else -> mobileText(language, "语音输入", "Voice input", "Голосовой ввод", "음성 입력", zhHant = "語音輸入", yue = "語音輸入")
    }
}

private fun billingCycleRank(cycle: String?): Int = when (cycle) {
    "weekly" -> 10
    "monthly" -> 20
    "quarterly" -> 30
    "yearly", "annual" -> 40
    else -> 100
}

private fun billingCycleTitle(language: MobileLanguage, cycle: String?): String = when (cycle) {
    "weekly" -> mobileText(language, "周付", "Weekly", "Неделя", "주간")
    "monthly" -> mobileText(language, "月付", "Monthly", "Месяц", "월간")
    "quarterly" -> mobileText(language, "季付", "Quarterly", "Квартал", "분기")
    "yearly", "annual" -> mobileText(language, "年付", "Yearly", "Год", "연간")
    else -> cycle?.takeIf { it.isNotBlank() } ?: "-"
}

private fun priceText(cents: Int, currency: String?): String {
    val code = currency?.takeIf { it.isNotBlank() }?.uppercase() ?: "USD"
    val symbol = when (code) {
        "USD" -> "US$"
        "CNY" -> "¥"
        "EUR" -> "€"
        "GBP" -> "£"
        else -> "$code "
    }
    return "$symbol${cents / 100}.${(cents % 100).toString().padStart(2, '0')}"
}

private fun paymentCreditsText(language: MobileLanguage, credits: Int): String {
    return mobileText(language, "$credits 积分", "$credits credits", "$credits кредитов", "$credits 크레딧")
}

private fun localizedPlanName(language: MobileLanguage, planCode: String): String = when (planCode) {
    "trial" -> mobileText(language, "免费试用", "Free Trial", "Пробный", "무료 체험", "免費試用", "免費試用")
    "free" -> mobileText(language, "免费版", "Free", "Бесплатный", "무료", "免費版", "免費版")
    "weekly" -> mobileText(language, "周套餐", "Weekly", "Недельный", "주간", "週套餐", "週套餐")
    "monthly" -> mobileText(language, "月套餐", "Monthly", "Месячный", "월간", "月套餐", "月套餐")
    "yearly" -> mobileText(language, "年套餐", "Yearly", "Годовой", "연간", "年套餐", "年套餐")
    "lite" -> mobileText(language, "轻量套餐", "Lite", "Лайт", "라이트", "輕量套餐", "輕量套餐")
    "standard" -> mobileText(language, "标准套餐", "Standard", "Стандарт", "스탠다드", "標準套餐", "標準套餐")
    "pro" -> mobileText(language, "专业套餐", "Pro", "Про", "프로", "專業套餐", "專業套餐")
    "none", "" -> mobileText(language, "无套餐", "No Plan", "Нет тарифа", "요금제 없음", "無套餐", "無套餐")
    else -> planCode.uppercase()
}

/** 积分卡片内的一行「标签 —— 值」，白色文字，用于 ProfileHeroCard。 */
@Composable
private fun HeroCreditInfoRow(label: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.85f)
        )
        Spacer(Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
            color = Color.White
        )
    }
}

/**
 * 将后端返回的 ISO8601 UTC 字符串（带/不带小数秒，或多种回退格式）格式化为本地日期（仅年月日）。
 * 无法解析或为空时返回 null。
 */
private fun formatServerDate(raw: String?): String? {
    if (raw.isNullOrBlank()) return null
    val instant: java.time.Instant? = runCatching { java.time.Instant.parse(raw) }.getOrNull()
        ?: run {
            val patterns = listOf(
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"
            )
            patterns.firstNotNullOfOrNull { p ->
                runCatching {
                    val fmt = java.time.format.DateTimeFormatter.ofPattern(p)
                        .withZone(java.time.ZoneOffset.UTC)
                    java.time.LocalDateTime.parse(raw, java.time.format.DateTimeFormatter.ofPattern(p))
                        .toInstant(java.time.ZoneOffset.UTC)
                }.getOrNull()
            }
        }
    if (instant == null) return null
    return runCatching {
        java.time.format.DateTimeFormatter
            .ofLocalizedDate(java.time.format.FormatStyle.MEDIUM)
            .withZone(java.time.ZoneId.systemDefault())
            .format(instant)
    }.getOrNull()
}

private fun mobileText(
    language: MobileLanguage,
    zh: String,
    en: String,
    ru: String,
    ko: String,
    zhHant: String = zh,
    yue: String = zh
): String {
    return when (language) {
        MobileLanguage.ZH_HANT -> zhHant
        MobileLanguage.YUE -> yue
        MobileLanguage.EN -> en
        MobileLanguage.RU -> ru
        MobileLanguage.KO -> ko
        else -> zh
    }
}

private fun isLobsterImeCurrent(context: Context): Boolean {
    return runCatching {
        val defaultMethod = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD
        ).orEmpty()
        defaultMethod.contains(context.packageName) &&
            defaultMethod.contains("LobsterIME")
    }.getOrDefault(false)
}
