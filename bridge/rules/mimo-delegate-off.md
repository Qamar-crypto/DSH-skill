<!-- mimo-delegate:off -->
## 委托 MiMo Desktop —— 已由用户关闭

用户显式关闭了这条流水线。**不要**加载 skill `mimo-delegate`、**不要**启动 MiMo Desktop、
**不要**把活派给它，也不要绕道调用 `_mimo_bridge` 里的任何脚本。
需要恢复时由用户显式说一声，然后跑下面的命令。

恢复：`powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\Deepseek Harness\_mimo_bridge\Set-Delegation.ps1' -Action on`
<!-- /mimo-delegate -->
