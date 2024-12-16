# RMS 使用指南

## 全新 RMS2 发布

RMS2 相较于 RMS1 实现了全方位提升：
- 压缩性能升级：不仅压缩公网连接，还能压缩数据体积，压缩率高达 30%-50%，同时 CPU 占用仅提升约 10%。
- 带宽优化：显著节约公网带宽，大幅提升在低带宽或网络质量较差环境下的表现。
- 兼容性要求：需配合 RustMinerSystem 服务端 v4.3.0 及以上版本，即可启用 RMS2 协议。

重要提醒：请 RMS1 用户尽快切换至 RMS2。RMS1 在稳定性和效率上已全面落后于 RMS2。

## 关于 RMS 客户端

RMS 安全客户端具备以下特点：
- 压缩连接数和数据，显著提高传输速度。
- 高安全性：防止中间人攻击和伪造请求。
- 多平台支持：
  - Linux
  - OpenWRT
  - Windows（图形化界面与命令行版本）

### 常见问题解答：
- [如何安装 RMS？](#安装指南)
- [Windows 图形界面版本白屏如何解决？](#windows-图形界面版本白屏)
- [什么是连接池模式？](#什么是连接池模式)
- [如何更改默认网页访问端口？](#如何更改默认网页访问端口)
- [如何设置 RMS 访问账号密码？](#如何设置-rms-访问账号密码)
- [如何配置 RMS 一对多服务器？](#我想-rms-一对多服务器如何使用)

# 安装指南

## Linux 安装

运行以下命令即可安装：

- 线路1（GitHub 官方地址，若无法访问请使用其他线路）：

```
bash <(curl -s -L https://raw.githubusercontent.com/EvilGenius-dot/RMS/main/install.sh)
```

- 线路2：

```
bash <(curl -s -L -k https://rustminersystem.com/install.sh)
```

## OpenWRT 安装

使用以下命令安装：

```
wget -N https://rustminersystem.com/install.sh; chmod +x ./install.sh; ./install.sh
```

注意：由于 OpenWRT 版本众多，脚本可能无法兼容所有版本。如遇问题，请手动下载适配的二进制文件进行安装。

## Windows 安装

### 图形化界面版本
- 下载地址：  
  https://github.com/EvilGenius-dot/RMS/raw/main/windows-gui/rms.exe
  
- 如遇白屏问题，请安装 WebView2：  
  https://github.com/EvilGenius-dot/RMS/raw/main/windows-gui/MicrosoftEdgeWebview2Setup.exe

### 非图形化命令行版本
- 下载地址：  
    https://github.com/EvilGenius-dot/RMS/raw/main/windows-no-gui/rms.exe

# 使用指南

### 如何使用？
1. 安装完成后，使用浏览器访问安装 RMS 客户端设备的 IP 地址（如 http://设备IP:42703）。
2. 进入网页后，填写推送地址即可。

建议：
- 请固定 RMS 安装设备的局域网 IP 地址。如果路由器使用 DHCP 动态分配 IP，可能导致设备重启后 IP 发生变化。

# 常见问题解答

### Windows 图形界面版本白屏

请安装 windows-gui 目录中的 MicrosoftEdgeWebview2Setup.exe 文件解决。

### 什么是连接池模式？

连接池模式是 RMS 的一项优化功能，可压缩 RMS 客户端至 RustMinerSystem 服务器的公网 TCP 连接数。

- 开启条件：需要 RustMinerSystem 服务端 v3.8.0 及以上版本。
- 功能特点：并非简单地将矿机合并为一台设备，而是压缩中间公网 TCP 连接数量。矿池内矿机数量保持不变。

压缩率计算公式：
「压缩率 = 接入矿机数量 / 最大连接数」
建议：
- 压缩率不要过高。通常 3-5 倍压缩率较为理想，具体配置需视 RMS 设备和服务器性能而定。

### 如何更改默认网页访问端口？

1. 打开非图形界面版本的 RMS 安装目录。
2. 修改 rms.conf 文件中的 PORT 配置项为所需端口。
3. 保存后重启程序即可生效。

### 如何设置 RMS 访问账号密码？

1. 在网页右上角，进入 设置 菜单。
2. 选择 设置用户名密码 进行配置。

### 我想 RMS 一对多服务器如何使用？

RMS 提供手动添加服务器功能：
1. 在 RMS 客户端内，选择 手动添加。
2. 按提示输入远程服务器地址即可完成配置。
