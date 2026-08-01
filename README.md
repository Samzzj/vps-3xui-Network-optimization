# VPS 3x-UI / Xray 一键网络优化脚本
##如果本脚本对你有帮助，欢迎给本项目点一个 ⭐ Star 支持一下！

## 功能简介
本脚本适用于 **Debian 12** 和 **Debian 13** 系统，专门针对 **1核 1G 内存** 的轻量级 VPS 进行**保守型网络调优**。主要优化内容包括：
- 🚀 开启 **BBR + FQ 队列** 算法，有效降低网络延迟，提升传输效率。
- 🔧 智能调整内核网络缓冲区（TCP 读写缓存及内存限制）。
- 🗑️ 限制系统日志（Journald）占用空间，防止小硬盘被日志撑满。
- 💾 自动创建 Swap 虚拟内存，避免 1G 内存吃紧时 VPS 直接卡死宕机。

##⚠️ 重要提示：脚本执行完毕后，请务必重启一次 VPS（在终端输入 reboot 回车），以确保 BBR、FQ 队列等所有内核参数及系统限制彻底生效。


## ⚡ 一键执行 (推荐)
请确保以 **root** 身份登录 VPS，直接复制下方代码框中的命令并在终端中执行（点击代码框右上角复制即可）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/Samzzj/vps-3xui-Network-optimization/main/install.sh)
