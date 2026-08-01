# VPS 3x-UI / Xray 一键网络优化脚本

适用于 **Debian 12** 和 **Debian 13**，针对 1 核 1G 内存的 VPS 进行保守型网络调优（开启 BBR + FQ 队列，调整缓冲区，限制日志等）。

## 一键执行（推荐）
以 root 身份运行：
```bash
bash <(curl -sL https://raw.githubusercontent.com/Samzzj/vps-3xui-Network-optimization/main/install.sh)
手动操作
仅 Debian 12：bash debian12.sh apply

仅 Debian 13：bash debian13.sh apply

验证优化效果
bash
bash debian13.sh verify   # 或 debian12.sh verify
回滚设置
bash
bash debian13.sh rollback
免责声明
请仅在测试通过后用于生产环境。

如果在操作过程中 GitHub 网页卡住，或者上传不成功，直接用浏览器刷新重试即可。祝你成功！如果搞定了，可以给我的第一个 GitHub 项目点个 Star（星星）纪念一下。
