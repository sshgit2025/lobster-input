/**
 * KeyboardPanelPage.ets — 软键盘 Panel 的页面载体(panel.setUiContent('ime/KeyboardPanelPage'))。
 * 对应安卓 onCreateInputView() 返回的整棵视图树;实际渲染全部委托给 UI 层的
 * KeyboardRoot 组件(ets/ime/view/KeyboardRoot.ets),状态经 ImeBus 驱动。
 * 已注册进 resources/base/profile/main_pages.json。
 */
import { KeyboardRoot } from './view/KeyboardRoot';

@Entry
@Component
struct KeyboardPanelPage {
  build() {
    Column() {
      KeyboardRoot()
    }
    .width('100%')
    .height('100%')
  }
}
