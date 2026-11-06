THEOS_DEVICE_IP = 127.0.0.1
THEOS_DEVICE_PORT = 2222

TARGET := iphone:clang:latest:14.0
ARCHS  = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RLSideswipeBot_v1

RLSideswipeBot_v1_FILES  = RLSideswipeBot_v1.m
RLSideswipeBot_v1_CFLAGS = -fobjc-arc -O2 -Wno-unused-function
RLSideswipeBot_v1_LDFLAGS = -framework UIKit \
                             -framework Foundation \
                             -framework CoreGraphics \
                             -framework QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

# After build, copy .dylib + .plist to DynamicLibraries automatically:
# make install  →  needs THEOS_DEVICE_IP set to your device IP
