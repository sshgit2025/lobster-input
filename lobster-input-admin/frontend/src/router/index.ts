import { createRouter, createWebHistory } from 'vue-router'
import { BASE_URL } from '@/constants'
import { checkAuth } from '@/api'

const router = createRouter({
  history: createWebHistory(BASE_URL),
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    {
      path: '/',
      component: () => import('@/layouts/MainLayout.vue'),
      children: [
        { path: '', redirect: '/dashboard' },
        { path: 'dashboard', name: 'dashboard', component: () => import('@/views/DashboardView.vue'), meta: { active: 'dashboard' } },
        { path: 'stats', name: 'stats', component: () => import('@/views/StatsView.vue'), meta: { active: 'stats' } },
        { path: 'users', name: 'users', component: () => import('@/views/UsersView.vue'), meta: { active: 'users' } },
        { path: 'invites', name: 'invites', component: () => import('@/views/InvitesView.vue'), meta: { active: 'invites' } },
        { path: 'rewards', name: 'rewards', component: () => import('@/views/RewardsView.vue'), meta: { active: 'rewards' } },
        { path: 'feedback', name: 'feedback', component: () => import('@/views/FeedbackView.vue'), meta: { active: 'feedback' } },
        { path: 'plans', name: 'plans', component: () => import('@/views/PlansView.vue'), meta: { active: 'plans' } },
        { path: 'plan-accounts', name: 'plan-accounts', component: () => import('@/views/PlanAccountsView.vue'), meta: { active: 'plan_accounts' } },
        { path: 'ledger', name: 'ledger', component: () => import('@/views/LedgerView.vue'), meta: { active: 'ledger' } },
        { path: 'payment-providers', name: 'payment-providers', component: () => import('@/views/PaymentProvidersView.vue'), meta: { active: 'payment_providers' } },
        { path: 'apple-iap', name: 'apple-iap', component: () => import('@/views/AppleIapView.vue'), meta: { active: 'apple_iap' } },
        { path: 'payment-orders', name: 'payment-orders', component: () => import('@/views/PaymentOrdersView.vue'), meta: { active: 'payment_orders' } },
        { path: 'payment-transactions', name: 'payment-transactions', component: () => import('@/views/PaymentTransactionsView.vue'), meta: { active: 'payment_transactions' } },
        { path: 'payment-refunds', name: 'payment-refunds', component: () => import('@/views/PaymentRefundsView.vue'), meta: { active: 'payment_refunds' } },
        { path: 'billing-catalog', name: 'billing-catalog', component: () => import('@/views/BillingCatalogView.vue'), meta: { active: 'billing_catalog' } },
        { path: 'billing-margin', name: 'billing-margin', component: () => import('@/views/BillingMarginView.vue'), meta: { active: 'billing_margin' } },
        { path: 'webhook-events', name: 'webhook-events', component: () => import('@/views/WebhookEventsView.vue'), meta: { active: 'webhook_events' } },
        { path: 'logs', name: 'logs', component: () => import('@/views/LogsView.vue'), meta: { active: 'logs' } },
        { path: 'alerts', name: 'alerts', component: () => import('@/views/AlertsView.vue'), meta: { active: 'alerts' } },
        { path: 'security', name: 'security', component: () => import('@/views/SecurityView.vue'), meta: { active: 'security' } },
        { path: 'config', name: 'config', component: () => import('@/views/ConfigView.vue'), meta: { active: 'config' } },
        { path: 'provider-config', name: 'provider-config', component: () => import('@/views/ProviderConfigView.vue'), meta: { active: 'provider_config' } },
        { path: 'user-dict', name: 'user-dict', component: () => import('@/views/UserDictView.vue'), meta: { active: 'user_dict' } },
        { path: 'personas', name: 'personas', component: () => import('@/views/PersonasView.vue'), meta: { active: 'personas' } },
        { path: 'agreements', name: 'agreements', component: () => import('@/views/AgreementsView.vue'), meta: { active: 'agreements' } },
        { path: 'account', name: 'account', component: () => import('@/views/AccountView.vue'), meta: { active: 'account' } },
      ],
    },
  ],
})

router.beforeEach(async (to) => {
  if (to.meta.public) return true
  const ok = await checkAuth()
  if (!ok) return { path: '/login', query: { redirect: to.fullPath } }
  return true
})

export default router
