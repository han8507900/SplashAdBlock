DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include SplashAdBlockBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplashAdBlock
SplashAdBlock_FILES = $(wildcard Hooks/*.xm Sources/*.m)
SplashAdBlock_CFLAGS = -fobjc-arc -Wno-error -I./Headers -I./Sources
SplashAdBlock_FRAMEWORKS = UIKit Foundation CoreFoundation
SplashAdBlock_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


