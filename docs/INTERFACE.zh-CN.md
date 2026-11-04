# 界面与视觉来源

0.4.0 的布局参考 [CC Switch 官方界面概览](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/zh/1-getting-started/1.3-interface.md) 的侧栏、页头、内容卡片与设置入口。未复制其代码、应用标志或图片。Agent Watch 的图标由 `scripts/make-icon.swift` 原创绘制，应用图形使用系统 SF Symbols（San Francisco Symbols，Apple 系统符号）。

主界面包含全部会话、按应用筛选、接入状态和设置。会话可按运行、待处理、结束与未知筛选，并按应用名称或会话标识搜索。等待授权、等待回答和失败优先排序；“本轮已结束”仅描述当前轮次。不同会话显示各自的标识，子任务独立标记。确认过的终态保留为历史记录，过期的进行中状态显示未知。

菜单栏随运行数、待处理数和未读结束数变化；暂停时显示暂停。菜单和可贴边的悬浮面板均提供近期会话、持续时间、打开应用及标记已读操作。“打开应用”暂不定位具体聊天。

设置支持跟随系统、浅色和深色。外观选择保存在本机；权限请求均由用户点击发起。实验观察和推断提醒默认关闭。

## 开发预览

下面的图片由当前 SwiftUI 视图离屏渲染，使用显式标记的合成会话；不是实际客户端兼容性验收。预览模式不启动采集器，不读取或写入监控历史，不请求权限、不发送通知。

![浅色界面，合成数据](images/dashboard-light.png)

![深色界面，合成数据](images/dashboard-dark.png)

构建后可运行 `AgentWatch --render-previews /absolute/output/directory` 重新生成预览。该参数仅用于开发，输出包括浅色、深色、最小窗口尺寸、菜单、设置和接入页。
