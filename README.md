# fnOS 腾讯云 SSL 证书自动续期 + 到期提醒

在飞牛 fnOS 上运行的**一键部署**脚本:自动检查腾讯云免费 SSL 证书(90 天),距到期不足指定天数(默认 20 天)时**自动申请新证书 → DNS 自动验证 → 自动下载 → 写入本地目录**;同时把到期倒计时推送到**飞牛系统通知中心**,并在 NAS 上生成一份**倒计时提醒 txt 文件**。

## 功能

- ✅ 每天自动检查(默认 03:30),距到期 ≤ 20 天自动申请新证书并下载
- ✅ 腾讯云 DNS 自动验证(`DNS_AUTO`,域名 DNS 需托管在腾讯云 DNSPod)
- ✅ 证书(证书链 + 私钥)写入本地目录,并按日期归档一份副本
- ✅ 飞牛系统通知中心推送提醒(到期倒计时 / 续期成功 / 异常告警)
- ✅ NAS 本地生成倒计时 txt 文件
- ✅ 开机自检:NAS 重启后自动恢复定时检查
- ✅ 一键安装 / 一键卸载

## 环境要求

- 飞牛 fnOS(默认存储结构,`/vol1/1000` 存在)
- Python 3(fnOS 自带)
- 腾讯云账号,且域名 DNS 托管在腾讯云 DNSPod(自动验证必需)
- SSH 登录 NAS 的管理员账号(用于执行脚本、发送系统通知)

## 一键部署

> 本仓库为私有仓库,推荐**方式一(ZIP 上传)**,全程无需在 NAS 上配置 GitHub 凭据。

### 方式一:下载 ZIP 上传(推荐)

1. 在电脑浏览器(已登录 GitHub)打开本仓库页面,点 **Code → Download ZIP** 下载;
2. 通过飞牛网页文件管理器,把 ZIP 上传到 `/vol1/1000` 并解压;
3. SSH 登录 NAS:

```bash
cd /vol1/1000/fnos-tencent-ssl-autorenew
bash install.sh
```

### 方式二:git clone(需在 NAS 配置只读访问令牌)

1. 在 GitHub 创建一个只读的 Fine-grained token:Settings → Developer settings → Personal access tokens → Fine-grained tokens → 仅勾选本仓库 + `Contents (Read-only)`;
2. SSH 登录 NAS:

```bash
cd /vol1/1000
git clone https://<你的token>@github.com/laoye9999/fnos-tencent-ssl-autorenew.git
cd fnos-tencent-ssl-autorenew
# 克隆完成后清除记录在 .git/config 里的令牌:
git remote set-url origin https://github.com/laoye9999/fnos-tencent-ssl-autorenew.git
bash install.sh
```

### 安装过程

执行 `bash install.sh` 后,脚本会交互式询问(只需填一次,自动写入配置):

| 配置项 | 说明 |
| --- | --- |
| SecretId / SecretKey | 腾讯云 API 密钥([获取地址](https://console.cloud.tencent.com/cam/capi)),输入时不回显 |
| 域名 | 支持多个,英文逗号分隔,如 `www.abc.com,abc.com` |
| 提前几天续期 | 默认 20 天 |
| 证书输出目录 | 默认 `/vol1/1000/certs` |
| 倒计时提醒文件路径 | 默认 `/vol1/1000/证书到期倒计时.txt` |
| NAS sudo 密码 | 用于发送飞牛系统通知(与 SSH 登录密码相同) |

> 💡 也可以在仓库目录手动创建 `config.json`(参考 [config.json.example](config.json.example))再执行 `bash install.sh`,脚本会检测到并跳过所有提问。

安装完成后:

- 脚本安装到 `/vol1/1000/tencent-ssl/`
- 定时任务:每天 **03:30** 检查续期 + **开机自检**
- 证书输出:`<输出目录>/<域名>/<域名>.crt` 和 `<域名>.key`(fullchain + 私钥),另有 `archive/日期/` 归档

证书可直接给 Lucky / Nginx 等反向代理工具使用。

## 一键卸载

```bash
cd /vol1/1000/fnos-tencent-ssl-autorenew
bash uninstall.sh
```

会删除定时任务和 `/vol1/1000/tencent-ssl/` 脚本目录;是否删除已下载的证书、提醒文件,脚本会逐项询问。

## 手动测试

```bash
# 只检查(不到期就不申请,但会更新通知和倒计时文件)
/usr/bin/python3 /vol1/1000/tencent-ssl/renew.py

# 强制申请一张新证书
/usr/bin/python3 /vol1/1000/tencent-ssl/renew.py --force
```

日志:`/vol1/1000/tencent-ssl/renew.log`(定时任务输出在 `cron.log`)。

## 工作原理

```
定时任务(每天 03:30 + 开机自检)
   │
   ▼
renew.py
   ├─ 查询该域名最新免费证书,距到期 > 20 天 → 跳过,仅更新提醒
   ├─ 距到期 ≤ 20 天(或首次部署) → ApplyCertificate 申请
   ├─ DNS_AUTO 自动验证 → 轮询签发状态(最长 20 分钟)
   ├─ 下载证书 ZIP → 解出证书链 + 私钥
   ├─ 写入 <output_dir>/<域名>/(+ 按日期归档)
   ├─ 更新倒计时提醒 txt 文件
   └─ 推送飞牛系统通知中心(通过 PostgreSQL 写入 notify 表,自动覆盖旧通知不堆积)
```

## 安全提醒

- `config.json` 包含腾讯云 API 密钥和 NAS 密码,安装时权限已设为 `600`,**请勿提交到 GitHub 或分享**;
- 本仓库不含任何真实密钥/证书,首次部署需自行填写;
- 建议为腾讯云 API 密钥开启最小权限(仅 SSL 证书相关)。

## 目录结构

```
.
├── install.sh            # 一键部署
├── uninstall.sh          # 一键卸载
├── renew.py              # 续期 + 通知主脚本
├── config.json.example   # 配置模板
└── lib/                  # Python 依赖(离线自带,无需 pip 安装)
```

`lib/` 为离线打包的第三方依赖(requests、tencentcloud-sdk-python、urllib3、certifi、charset-normalizer、idna),各依赖许可证见 `lib/*/licenses/`,版权归各自作者所有。本项目代码采用 MIT 许可证。
