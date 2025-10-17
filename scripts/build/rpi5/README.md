# Mesa V3DV Vulkan Driver for Raspberry Pi 5

macOS에서 Docker를 사용해 라즈베리파이 5용 Mesa V3DV Vulkan 드라이버를 크로스 컴파일하는 스크립트입니다.

## 파일 구성

- `Dockerfile.rpi5` - Docker 이미지 설정 (Ubuntu 22.04 + ARM64 툴체인)
- `cross-arm64.txt` - Meson 크로스 컴파일 설정 (Cortex-A76 최적화)
- `build-rpi5.sh` - 컨테이너 내 빌드 스크립트
- `docker-build.sh` - 메인 빌드 실행 스크립트

## 사용 방법

Mesa 루트 디렉토리에서 실행:

```bash
cd /path/to/mesa
./scripts/build/rpi5/docker-build.sh
```

## 빌드 결과

성공시 다음 파일이 생성됩니다:
- `build-rpi5/src/broadcom/vulkan/libvulkan_broadcom.so`
- `build-rpi5/broadcom_icd.aarch64.json`

## 라즈베리파이 5에 설치

```bash
# 드라이버 복사
scp build-rpi5/src/broadcom/vulkan/libvulkan_broadcom.so pi@your-rpi5:/usr/lib/aarch64-linux-gnu/

# ICD 설정 복사
scp build-rpi5/broadcom_icd.aarch64.json pi@your-rpi5:/usr/share/vulkan/icd.d/

# 확인
vulkaninfo
```

## 요구사항

- macOS with Docker Desktop
- Mesa 소스 코드
- 약 1GB 디스크 공간 (Docker 이미지)