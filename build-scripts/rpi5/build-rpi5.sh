#!/bin/bash

# Docker 컨테이너에서 실행될 빌드 스크립트

set -e

echo "Mesa V3DV Vulkan Driver 빌드 시작..."
echo "현재 디렉토리: $(pwd)"
echo "파일 목록:"
ls -la

# 빌드 디렉토리 생성
mkdir -p build-rpi5
cd build-rpi5
echo "빌드 디렉토리 생성 완료: $(pwd)"

# Meson 설정
meson setup .. \
  --cross-file=../build-scripts/rpi5/cross-arm64.txt \
  -Dvulkan-drivers=broadcom \
  -Dgallium-drivers=v3d,vc4 \
  -Dplatforms=wayland,x11 \
  -Dgles1=disabled \
  -Dgles2=enabled \
  -Dopengl=true \
  -Dgbm=enabled \
  -Degl=enabled \
  -Dglx=disabled \
  -Dllvm=disabled \
  -Dglvnd=disabled \
  -Dbuild-tests=false \
  -Dprefix=/opt/mesa-rpi5 \
  -Dlibdir=lib

echo "Meson 설정 완료. 빌드 시작..."

# 병렬 빌드
ninja -j$(nproc)

echo "빌드 완료!"

# 결과물 확인
echo "생성된 Vulkan 드라이버:"
ls -la src/broadcom/vulkan/libvulkan_broadcom.so*

echo "설치 (선택적):"
echo "ninja install"