"""
PipelineSelector — 流程选择器抽象层。

职责：根据客户端传递的语言类型（X-Accept-Language Header）选择对应的处理流程。

设计原则：
  - 当前仅有 StandardFlow 唯一流程，选择器始终返回它
  - 语言类型已传入但暂时只用于路由，待后续新增语言专属流程时扩展注册表
  - 找不到匹配流程时自动降级为默认流程（StandardFlow）

扩展方式（未来新增流程时）：
  1. 继承 BasePipelineFlow 实现新流程类
  2. 在 PipelineSelector._FLOW_REGISTRY 中注册 {language: flow_instance}
     例如：{"ja": JapaneseOptimizedFlow()}
"""
import logging
from typing import Optional

from app.core.lang_utils import normalize_lang
from app.services.pipeline.flow.base import BasePipelineFlow
from app.services.pipeline.flow.standard_flow import STANDARD_FLOW

logger = logging.getLogger("voice_input.pipeline_selector")

_DEFAULT_FLOW: BasePipelineFlow = STANDARD_FLOW

_FLOW_REGISTRY: dict[str, BasePipelineFlow] = {}


class PipelineSelector:
    """
    流程选择器：根据语言类型从注册表中选择最合适的处理流程。

    当前注册表为空，所有请求均走默认 StandardFlow。
    后续按语言扩展时向 _FLOW_REGISTRY 注册即可，无需修改此类。
    """

    @staticmethod
    def select(client_ui_lang: Optional[str] = None) -> BasePipelineFlow:
        """
        根据客户端 UI 语言类型选择处理流程。

        :param client_ui_lang: 客户端 X-Accept-Language Header 值（如 zh / en / ja）
        :return: 对应的 BasePipelineFlow 实例，无匹配时返回默认 StandardFlow
        """
        if client_ui_lang:
            lang_key = normalize_lang(client_ui_lang)
            flow = _FLOW_REGISTRY.get(lang_key)
            if flow is not None:
                logger.info(
                    "[PipelineSelector] client_ui_lang=%r → flow=%r",
                    client_ui_lang, flow.flow_name,
                )
                return flow
            logger.debug(
                "[PipelineSelector] client_ui_lang=%r not in registry → default flow=%r",
                client_ui_lang, _DEFAULT_FLOW.flow_name,
            )
        else:
            logger.debug(
                "[PipelineSelector] no client_ui_lang → default flow=%r",
                _DEFAULT_FLOW.flow_name,
            )

        return _DEFAULT_FLOW
