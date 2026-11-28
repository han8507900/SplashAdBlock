THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AlarmPill
AlarmPill_FILES = Tweak.xm
AlarmPill_CFLAGS = -fobjc-arc -Wno-error

include $(THEOS_MAKE_PATH)/tweak.mk
