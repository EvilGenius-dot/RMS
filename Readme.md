# RMS

### RMS安全客户端, 可压缩设备至RustMinerSystem的连接数以及数据, 传输速度快, 且无法被中间人攻击及伪造请求攻击。


# Linux安装

## 运行以下命令根据提示安装

#### 线路1（github官方地址, 如无法访问请使用其他线路）:

```sh
bash <(curl -s -L https://raw.githubusercontent.com/EvilGenius-dot/RMS/main/install.sh)
```

#### 线路2:

```sh
bash <(curl -s -L -k http://rustminersystem.com/install.sh)
```

## OPEN-WRT安装

#### open-wrt输入以下命令进行安装

```
 wget -N http://rustminersystem.com/install.sh;chmod 777 ./install.sh;./install.sh
```

# WINDOWS安装

## 带有图形化界面的客户端

#### 下载地址
```sh
https://github.com/EvilGenius-dot/RMS/raw/main/windows-gui/rms.exe
```

#### 图形化界面版本打开如果白屏闪退，请安装webview2, 下载地址
```sh
https://github.com/EvilGenius-dot/RMS/raw/main/windows-gui/MicrosoftEdgeWebview2Setup.exe
```

## 非图形化windows客户端（命令行）

```sh
https://github.com/EvilGenius-dot/RMS/raw/main/windows-no-gui/rms.exe
```

# 运行

安装完毕之后，如果是非windows-gui带图形界面的版本, 请在浏览器内访问安装RMS客户端设备地址，如 ip:42703，进入网页后填入推送地址即可。

安装RMS设备请尽量固定局域网IP，如果您的路由器是DHCP动态分配ip，则有可能安装设备重启后IP发生变化。