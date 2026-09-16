"""支付/计费领域的稳定枚举常量。

单独成模块,供 API 层(payments.py)与渠道 adapter 共享,避免 adapter 反向 import payments 造成循环。
"""

# 结算模式
SETTLEMENT_FULL_PRICE = "full_price"                 # 全价结算(首购/续费/加购)
SETTLEMENT_PRORATED_DIFFERENCE = "prorated_difference"  # 升级按差价结算
SETTLEMENT_MODES = {SETTLEMENT_FULL_PRICE, SETTLEMENT_PRORATED_DIFFERENCE}

# 扣费类型
CHARGE_TYPE_MANUAL_PURCHASE = "manual_purchase"     # 用户主动结账(首购/升级)
CHARGE_TYPE_AUTO_RENEWAL = "auto_renewal"           # 平台托管自动续费(无 checkout)
CHARGE_TYPE_SCHEDULED_DOWNGRADE = "scheduled_downgrade"  # 到期定时降级激活
CHARGE_TYPES = {CHARGE_TYPE_MANUAL_PURCHASE, CHARGE_TYPE_AUTO_RENEWAL, CHARGE_TYPE_SCHEDULED_DOWNGRADE}
