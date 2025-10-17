#!/bin/bash

# Docker 컨테이너에서 실행될 빌드 스크립트

set -e

echo "Mesa V3DV Vulkan Driver 빌드 시작..."
echo "현재 디렉토리: $(pwd)"
echo "파일 목록:"
ls -la

# 빌드 디렉토리 생성
mkdir -p build/rpi5
cd build/rpi5
echo "빌드 디렉토리 생성 완료: $(pwd)"

# Meson 설정
meson setup ../../.. \
  --cross-file=../../../scripts/build/rpi5/cross-arm64.txt \
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

# 수동 설치 (선택적)
echo ""
echo "수동 설치를 원하면 다음 명령어들을 실행하세요:"
echo ""
echo "# 설치 디렉토리 생성"
echo "mkdir -p /opt/mesa-rpi5/lib"
echo "mkdir -p /opt/mesa-rpi5/include"
echo ""
echo "# Vulkan 드라이버 복사"
echo "cp src/broadcom/vulkan/libvulkan_broadcom.so /opt/mesa-rpi5/lib/"
echo ""
echo "# Vulkan ICD 매니페스트 파일 설치"
echo "cp src/broadcom/vulkan/broadcom_icd.cortex-a76.json /usr/share/vulkan/icd.d/"
echo ""
echo "# EGL 및 기타 라이브러리 복사"
echo "cp src/egl/libEGL.so* /opt/mesa-rpi5/lib/"
echo "cp src/mesa/glapi/es2api/libGLESv2.so* /opt/mesa-rpi5/lib/"
echo "cp src/gallium/targets/dri/libgallium-*.so /opt/mesa-rpi5/lib/"
echo ""
echo "# 헤더 파일 복사"
echo "cp -r ../include/* /opt/mesa-rpi5/include/"
echo ""
echo "또는 자동 설치: ninja install"