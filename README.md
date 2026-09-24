# Immich 懒猫应用适配器

本仓库为上游 [Immich](https://github.com/immich-app/immich) 生成并提交懒猫微服官方应用 `dev.libr.immich`。Immich 源代码和镜像仍由上游维护；这里保存 LPK 配置、当前商店版本基线和自动更新状态。

自动流程每天检查稳定的 `vX.Y.Z` Git 标签。发现新版本后，`lazycat-action` 会把 Immich Server、Machine Learning、官方 PostgreSQL 和 Valkey 作为同一个镜像集合处理：所有镜像均完成平台检查和官方仓库转存后，才一次性更新 Manifest、构建 LPK 并提交审核。

## 持久化兼容约束

正式版 `3.0.3` 已使用以下路径，后续版本不得改名，否则升级后会丢失已有数据视图：

- `/lzcapp/var/photos`：照片、视频、缩略图和转码文件；
- `/lzcapp/var/data`：PostgreSQL 数据；
- `/lzcapp/var/machine`：机器学习模型缓存；
- 服务名保持 `immich`、`machine-learning`、`redis` 和 `postgres`。

## GitHub 设置

在本仓库的 Actions secrets 中设置 `LZC_API_TOKEN`。可选设置 `LZC_API_HOST`；不设置时使用生产应用商店地址。仓库 Actions 权限需要允许写入 Contents，使流水线能够提交更新后的版本、Manifest 和状态锁。

推送配置只进行 dry-run。正式更新可在 **Actions → Update Immich for LazyCat → Run workflow** 中取消勾选 dry-run，或等待每日定时任务。

本地只读检查：

```bash
lazycat-action run --operation check --config lazycat-action.yml --dry-run
```

`scripts/test-upgrade.sh` 会在隔离的 Docker Compose 项目中真实启动 `v3.0.3` 的 Server、Machine Learning、PostgreSQL 和 Valkey，写入数据库及照片目录标记，再用相同持久化目录升级到 `v3.2.2`。GitHub Actions 会验证四个服务恢复健康、Immich 数据库迁移成功且标记仍然存在；测试结束后自动删除容器和临时数据。
