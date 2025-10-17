# IP=192.168.0.33
IP=192.168.219.102

BUILD_DIR=build/rpi5/src/broadcom/vulkan
TARGET_PATH=/home/changhyun/Desktop/vulkan_driver

scp $BUILD_DIR/libvulkan_changhyun.so changhyun@$IP:$TARGET_PATH
scp $BUILD_DIR/changhyun_icd.json changhyun@$IP:$TARGET_PATH