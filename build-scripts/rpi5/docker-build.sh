#!/bin/bash

# macOS에서 Docker를 사용한 Mesa V3DV 빌드 스크립트

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_NAME="mesa-rpi5-builder"
BUILD_DIR="build-rpi5"

echo "Mesa V3DV Vulkan Driver Docker 빌드 시작..."

# Docker 이미지가 없으면 빌드
if [[ "$(docker images -q ${IMAGE_NAME} 2> /dev/null)" == "" ]]; then
    echo "Docker 이미지 빌드 중..."
    docker build -f build-scripts/rpi5/Dockerfile.rpi5 -t ${IMAGE_NAME} .
fi

# 빌드 디렉토리 정리 (선택적)
read -p "기존 빌드 디렉토리를 삭제하시겠습니까? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf ${BUILD_DIR}
    echo "빌드 디렉토리 삭제됨"
fi

# Docker 컨테이너에서 빌드 실행
echo "Docker 컨테이너에서 Mesa 빌드 실행..."
echo "실행 명령: docker run --rm -v ${SCRIPT_DIR}:/mesa ${IMAGE_NAME}"

if docker run --rm -v "${SCRIPT_DIR}:/mesa" -w /mesa ${IMAGE_NAME}; then
    echo "Docker 컨테이너 실행 완료"
else
    echo "Docker 컨테이너 실행 실패 (exit code: $?)"
    echo "디버그를 위해 대화식 모드로 컨테이너 실행:"
    echo "docker run --rm -it -v ${SCRIPT_DIR}:/mesa ${IMAGE_NAME} bash"
    exit 1
fi

# 결과 확인
if [ -f "${BUILD_DIR}/src/broadcom/vulkan/libvulkan_broadcom.so" ]; then
    echo "✅ 빌드 성공!"
    echo "생성된 파일:"
    ls -la "${BUILD_DIR}/src/broadcom/vulkan/libvulkan_broadcom.so"*
    echo ""
    echo "라즈베리파이 5로 복사하려면:"
    echo "scp ${BUILD_DIR}/src/broadcom/vulkan/libvulkan_broadcom.so pi@your-rpi5:/usr/lib/aarch64-linux-gnu/"
else
    echo "❌ 빌드 실패"
    exit 1
fi