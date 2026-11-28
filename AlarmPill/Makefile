THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

# 发布包：不带调试符号、版本号不加 +debug（体积更小）。必须在 include common.mk 之前
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AlarmPill
AlarmPill_FILES = Tweak.xm
AlarmPill_CFLAGS = -fobjc-arc -Wno-error

include $(THEOS_MAKE_PATH)/tweak.mk
