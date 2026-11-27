DEBUG = 0
FINALPACKAGE = 1

# 体积优先：-Oz（Theos 默认 -O2）。必须在 common.mk 之前赋值才生效。
OPTFLAG = -Oz

# Share the SDK and deployment targets with the PreferenceBundle.
include SplashAdBlockBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplashAdBlock
SplashAdBlock_FILES = $(wildcard Hooks/*.xm Sources/*.m)
# 链接期删未用代码与本地符号；ARCHS 在 SplashAdBlockBuild.mk 里定为单 arm64。
SplashAdBlock_CFLAGS = -fobjc-arc -Wno-error -I./Headers -I./Sources
SplashAdBlock_LDFLAGS = -Wl,-dead_strip -Wl,-x
SplashAdBlock_FRAMEWORKS = UIKit Foundation CoreFoundation
SplashAdBlock_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


