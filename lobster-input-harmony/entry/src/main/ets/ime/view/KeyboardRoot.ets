/**
 * 键盘面板根组件:组装打字键盘(候选栏+键区+波形)与语音面板(快捷行+录音球+符号板+人设板
 * +不可用面板),通过全局单例 ImeBus 与逻辑层解耦(IME 服务从 ImeBus 驱动本组件)。
 *
 * 用法(KeyboardPanelPage 中):
 *   Column() { KeyboardRoot() }
 * 服务侧初始化:
 *   ImeBus.getInstance().bindDelegate(delegateImpl)        // UI 事件出口
 *   controller.bind(ImeBus.getInstance())                  // ImeBus 实现 KeyboardRenderer
 *   ImeBus.getInstance().setPanelMode(ImePanelMode.TYPING) // 打字键盘 / VOICE 语音面板
 *
 * VOICE 态渲染完整语音面板(VoicePanelView,对齐安卓 LobsterIME.onCreateInputView 的
 * voicePanel/symbolPanel/personaPanel/unavailablePanel 视图树),状态来自
 * ImeBusState.voice 快照(服务层 refreshKeyboardUi 全量写入)。
 */
import { ImeBus, ImeBusState, ImePanelMode } from '../ImeBus'
import { TypingKeyboardView } from './TypingKeyboardView'
import { VoicePanelView } from './VoicePanelView'

@Component
export struct KeyboardRoot {
  @State busState: ImeBusState = ImeBus.getInstance().state

  build() {
    Column() {
      if (this.busState.panelMode === ImePanelMode.VOICE) {
        VoicePanelView({ state: this.busState })
      } else {
        TypingKeyboardView({ state: this.busState })
      }
    }
    .width('100%')
  }
}
