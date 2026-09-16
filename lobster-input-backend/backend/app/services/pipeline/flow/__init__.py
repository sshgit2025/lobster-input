"""
pipeline.flow — 流程管理层。

架构设计：
  PipelineManager（流程管理器）
    └── PipelineSelector（流程选择器，根据语言类型选择流程）
          └── BasePipelineFlow（流程基类）
                └── StandardFlow（唯一标准流程，封装4平台 Pipeline 集合）

调用方只需通过 PipelineManager.get_pipeline() 获取对应平台的 Pipeline 实例，
后续新增流程时只需新增 BasePipelineFlow 子类并在 PipelineSelector 中注册即可。
"""
from app.services.pipeline.flow.pipeline_manager import PipelineManager

__all__ = ["PipelineManager"]
