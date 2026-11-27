DEBUG ?= 0
FINALPACKAGE ?= 1
# 只编译 arm64：App Store 应用的进程是 arm64（arm64e 只用于系统进程/带特权签名的二进制），
# 插件注入 App 只需要 arm64 切片。双切片曾让 dylib 大一倍（270KB → 135KB），deb 40KB → 20KB。
# 旁证：同目录竞品「威锋去广告加强.dylib」就是单 arm64，且只针对 com.feng.New.WPForumClient，
# 在本机（A17 / iOS 17.3.1 / RootHide）能用 —— 说明 arm64 单切片足够。
ARCHS = arm64

# Rootless and Roothide require iOS 15 or newer.
ifneq ($(filter rootless roothide,$(THEOS_PACKAGE_SCHEME)),)
TARGET = iphone:clang:latest:15.0
else
TARGET = iphone:clang:latest:15.0
endif
