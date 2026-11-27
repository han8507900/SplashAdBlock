DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include SplashAdBlockBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplashAdBlock
SplashAdBlock_FILES = $(wildcard Hooks/*.xm Sources/*.m)
# -Os：体积优先（逻辑不依赖性能热点）；-Wl,-dead_strip / -x：链接期删未用代码与本地符号。
# 注意 ARCHS 必须是 arm64 + arm64e：App 进程是 arm64，系统/RootHide 侧要 arm64e，
# 只留一个会导致另一侧加载不到（fat 双切片是体积的大头，但不能砍）。
SplashAdBlock_CFLAGS = -fobjc-arc -Wno-error -Os -I./Headers -I./Sources
SplashAdBlock_LDFLAGS = -Wl,-dead_strip -Wl,-x
SplashAdBlock_FRAMEWORKS = UIKit Foundation CoreFoundation
SplashAdBlock_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


