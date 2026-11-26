DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsSplashAdBlockBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsSplashAdBlock
AxsSplashAdBlock_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsSplashAdBlock_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsSplashAdBlock_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsSplashAdBlock_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


