# Raspberry Pi 5 Vulkan Driver (V3DV) - Complete Architecture Guide

> Mesa V3D Vulkan 드라이버 완전 분석: 핵심 폴더 구조, 동작 원리, 컴포넌트 간 관계

## 개요

이 문서는 **Raspberry Pi 5 (Broadcom VideoCore V3D GPU)** Vulkan 드라이버의 전체 아키텍처를 설명합니다.

**드라이버 이름**: V3DV
**지원 API**: Vulkan 1.3
**대상 하드웨어**:
- Raspberry Pi 4: BCM2711 (V3D 4.2)
- Raspberry Pi 5: BCM2712 (V3D 7.1)

**코드 규모**: 약 38,000 라인 (V3DV 드라이버 부분)

---

## 1. Vulkan 드라이버 동작 개요

### 1.1 전체 아키텍처

```
┌──────────────────────────────────────────────────────┐
│                Vulkan Application                    │
│              (vkCreateDevice, vkCmdDraw)             │
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│           src/vulkan/runtime/                        │  ← Mesa 공통 레이어
│     (vk_device, vk_queue, vk_command_buffer)         │     (모든 드라이버 공유)
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│           src/broadcom/vulkan/  (V3DV)               │  ← V3D 드라이버 구현
│  • 커맨드 버퍼 기록 (v3dv_cmd_buffer.c)              │
│  • 파이프라인 생성 (v3dv_pipeline.c)                 │
│  • GPU 작업 제출 (v3dv_queue.c)                      │
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│        src/broadcom/cle/ + src/broadcom/compiler/    │  ← 하드웨어 코드 생성
│  • 커맨드 리스트 패킷 (CLE)                          │
│  • 셰이더 컴파일 (SPIR-V → QPU)                      │
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│           include/drm-uapi/v3d_drm.h                 │  ← 커널 인터페이스
│       (DRM_IOCTL_V3D_SUBMIT_CL, CREATE_BO)           │
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│      Linux Kernel: drivers/gpu/drm/v3d/              │  ← V3D 커널 드라이버
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│              V3D GPU Hardware                        │  ← Tile-Based GPU
│    (Binning → Rendering → Display)                   │
└──────────────────────────────────────────────────────┘
```

### 1.2 핵심 동작 흐름

```
[1. 초기화]
vkCreateInstance/Device
  → src/vulkan/runtime/: 공통 객체 초기화
  → src/broadcom/vulkan/v3dv_device.c: V3D 디바이스 열기 (/dev/dri/renderD128)
  → src/broadcom/vulkan/v3dv_bo.c: BO 캐시 초기화

[2. 파이프라인 생성]
vkCreateGraphicsPipeline
  → src/broadcom/vulkan/v3dv_pipeline.c: 파이프라인 상태 설정
  → src/broadcom/compiler/: SPIR-V → NIR → VIR → QPU 컴파일
  → src/broadcom/qpu/: QPU 바이너리 인코딩

[3. 렌더링 커맨드 기록]
vkCmdDraw/vkCmdDispatch
  → src/vulkan/runtime/vk_command_buffer.c: 공통 커맨드 처리
  → src/broadcom/vulkan/v3dv_cmd_buffer.c: V3D 커맨드 기록
  → src/broadcom/vulkan/v3dv_cl.c: BCL/RCL 생성
  → src/broadcom/cle/: 하드웨어 패킷 인코딩 (v3d_packet.xml 기반)

[4. GPU 제출]
vkQueueSubmit
  → src/vulkan/runtime/vk_queue.c: 공통 큐 로직
  → src/broadcom/vulkan/v3dv_queue.c: handle_cl_job()
    - BO 리스트 준비
    - drm_v3d_submit_cl 구조체 작성
    - v3d_ioctl(DRM_IOCTL_V3D_SUBMIT_CL)
  → Kernel: 커맨드 리스트 검증 및 GPU 큐 제출

[5. 하드웨어 실행]
V3D GPU:
  - Binning Phase: BCL 실행, 타일별 작업 리스트 생성
  - Rendering Phase: RCL 실행, Fragment Shader
  - IRQ 발생 → 커널 → syncobj 시그널

[6. 동기화]
vkWaitForFences
  → src/vulkan/runtime/vk_sync.c: Fence 대기
  → 완료
```

---

## 2. 핵심 디렉토리 구조 및 역할

### 2.1 드라이버 코어: `src/broadcom/vulkan/`

**역할**: V3DV Vulkan 드라이버의 메인 구현 (약 38,000 라인)

#### 주요 컴포넌트

| 카테고리 | 파일 | 역할 | 의존 관계 |
|---------|------|------|----------|
| **디바이스 관리** | `v3dv_device.c` (111KB) | 물리/논리 디바이스 초기화<br>DRM fd 열기, GPU 파라미터 조회 | → `include/drm-uapi/v3d_drm.h`<br>→ `src/vulkan/runtime/vk_device.c` |
| | `v3dv_private.h` | 드라이버 내부 구조체 정의 | 모든 V3DV 파일이 include |
| **메모리 관리** | `v3dv_bo.c/h` | Buffer Object 할당/해제<br>BO 캐시 관리 (64MB) | → `DRM_IOCTL_V3D_CREATE_BO`<br>→ `DRM_IOCTL_V3D_MMAP_BO` |
| **커맨드 버퍼** | `v3dv_cmd_buffer.c` (176KB) | Vulkan 커맨드 기록 (vkCmd*)<br>Draw/Dispatch 처리 | → `v3dv_cl.c` (CL 생성)<br>→ `src/vulkan/runtime/vk_command_buffer.c` |
| **GPU 제출** | `v3dv_queue.c` | 작업 제출 및 동기화<br>handle_cl_job(), handle_csd_job() | → `DRM_IOCTL_V3D_SUBMIT_CL`<br>→ `src/vulkan/runtime/vk_queue.c` |
| **Command List** | `v3dv_cl.c/h` | BCL/RCL 커맨드 리스트 생성 | → `src/broadcom/cle/` (패킷 매크로) |
| **파이프라인** | `v3dv_pipeline.c`<br>`v3dvx_pipeline.c` | 그래픽/컴퓨트 파이프라인 생성<br>하드웨어 버전별 코드 | → `src/broadcom/compiler/` (셰이더 컴파일) |
| **리소스** | `v3dv_image.c` | 이미지/텍스처, 타일링 레이아웃 | → `src/broadcom/common/v3d_tiling.c` |
| | `v3dv_formats.c` | Vulkan ↔ V3D 포맷 변환 | → `src/vulkan/util/vk_format.c` |
| **렌더링** | `v3dv_pass.c` | 렌더패스 구현 | |
| | `v3dv_meta_clear.c` (47KB) | 클리어 연산 최적화 | → `src/vulkan/runtime/vk_meta.c` |
| **WSI** | `v3dv_wsi.c` | Window System Integration | → `src/vulkan/wsi/wsi_common.c` |

**핵심 데이터 구조**:
```c
// v3dv_private.h
struct v3dv_device {
   struct vk_device vk;              // ← 공통 레이어 구조체
   struct v3dv_physical_device *pdevice;
   int render_fd;                    // DRM 파일 디스크립터
   struct v3dv_bo_cache bo_cache;    // BO 캐시
   struct v3d_device_info devinfo;   // GPU 버전 정보
};

struct v3dv_cmd_buffer {
   struct vk_command_buffer vk;      // ← 공통 레이어
   struct v3dv_cl bcl;               // Binning Command List
   struct v3dv_cl rcl;               // Rendering Command List
   struct list_head jobs;            // 작업 리스트
};
```

---

### 2.2 셰이더 컴파일러: `src/broadcom/compiler/`

**역할**: SPIR-V → V3D QPU 바이너리 변환

#### 컴파일 파이프라인

```
[1. SPIR-V → NIR]
Mesa 공통 레이어 (compiler/spirv/)
  ↓
[2. NIR 최적화]
src/broadcom/compiler/v3d_nir_lower_*.c
  - v3d_nir_lower_io.c: Input/Output lowering
  - v3d_nir_lower_image_load_store.c: 이미지 연산
  - v3d_nir_lower_txf_ms.c: 멀티샘플 텍스처
  ↓
[3. NIR → VIR (V3D IR)]
src/broadcom/compiler/nir_to_vir.c (202KB)
  - V3D 중간 표현 생성
  ↓
[4. VIR 최적화]
vir_optimize.c
  ↓
[5. VIR → QPU]
vir_to_qpu.c
  ↓
[6. 레지스터 할당 & 스케줄링]
qpu_schedule.c (119KB)
  - QPU 파이프라인 최적화
  ↓
[7. 바이너리 인코딩]
src/broadcom/qpu/qpu_pack.c (98KB)
  ↓
[QPU Machine Code]
GPU로 제출
```

**주요 파일**:
- `v3d_compiler.h` (55KB): 컴파일러 구조체, 레지스터 정의
- `nir_to_vir.c`: NIR → VIR 변환 (가장 복잡한 부분)
- `qpu_schedule.c`: 성능 최적화의 핵심

**QPU (Quad Processor Unit)**:
- 16-way SIMD 프로세서
- 픽셀 4개(Quad) × 4 = 16개 병렬 처리
- 32개 물리 레지스터
- TMU (Texture Memory Unit) 통합

---

### 2.3 하드웨어 패킷 생성: `src/broadcom/cle/`

**역할**: Command List Encoder - V3D 하드웨어 명령어 생성

#### 핵심 메커니즘

**1. `v3d_packet.xml` (88KB)**
- XML로 모든 하드웨어 레지스터/명령 정의
- 예시:
```xml
<packet name="GL_SHADER_STATE" code="64">
  <field name="address" size="28" start="0" type="address"/>
  <field name="number_of_attribute_arrays" size="5" start="28"/>
</packet>
```

**2. `gen_pack_header.py`**
- 빌드 시 XML → C 헤더 생성
- 출력: `v3dx_pack.h` (매크로)

**3. 사용 예시**:
```c
// v3dv_cl.c
cl_emit(&job->bcl, GL_SHADER_STATE, shader) {
   shader.address = v3dv_cl_address(shader_bo, 0);
   shader.number_of_attribute_arrays = num_attrs;
}
```

**4. 디코더**: `v3d_decoder.c/h`
- 디버깅용: 바이너리 CL → 사람이 읽을 수 있는 형태
- `V3D_DEBUG=cl` 환경변수로 활성화

---

### 2.4 공통 유틸리티: `src/broadcom/common/`

**역할**: Vulkan/OpenGL 드라이버 공유 코드

| 파일 | 역할 | 사용처 |
|------|------|--------|
| `v3d_device_info.h/c` | GPU 버전 정보<br>V3D 3.3/4.1/4.2/7.1 | 모든 드라이버 |
| `v3d_tiling.h/c` | 타일 메모리 레이아웃 계산<br>UIF, T-format | `v3dv_image.c` |
| `v3d_debug.h/c` | 디버그 플래그 (V3D_DEBUG) | 전역 |
| `v3d_limits.h` | 하드웨어 제한값 | `v3dv_limits.h` |
| `v3d_tfu.h` | TFU (Texture Formatting Unit) | `v3dv_queue.c` |
| `v3d_csd.h` | CSD (Compute Shader Dispatch) | `v3dv_queue.c` |

**타일링 레이아웃**:
- **UIF (Unified Image Format)**: 효율적인 메모리 액세스를 위한 V3D 고유 포맷
- 타일 크기: 일반적으로 64×64 픽셀

---

### 2.5 Mesa 공통 레이어: `src/vulkan/`

**중요**: 모든 Mesa Vulkan 드라이버가 공유하는 인프라

#### `src/vulkan/runtime/` (110+ 파일)

**역할**: Vulkan 객체 기본 구현 제공

**V3DV 통합 방식**:
```c
// V3DV 디바이스 구조체는 vk_device를 포함
struct v3dv_device {
   struct vk_device vk;  // ← 공통 레이어 구조체
   // V3D 특화 필드...
};

// 초기화
VkResult v3dv_CreateDevice(...) {
   // 1. 공통 레이어 초기화
   vk_device_init(&device->vk, &physical_device->vk, ...);

   // 2. V3D 특화 초기화
   device->render_fd = open("/dev/dri/renderD128", ...);
   v3dv_bo_cache_init(&device->bo_cache);
}
```

**주요 컴포넌트**:

| 헤더 | 역할 | V3DV 사용 |
|------|------|----------|
| `vk_device.h/c` | VkDevice 기본 구조체 | v3dv_device.c |
| `vk_physical_device.h/c` | VkPhysicalDevice | v3dv_device.c |
| `vk_command_buffer.h/c` | VkCommandBuffer 라이프사이클 | v3dv_cmd_buffer.c |
| `vk_queue.h/c` | VkQueue 및 제출 로직 | v3dv_queue.c |
| `vk_sync.h/c` | Fence/Semaphore 추상화 | v3dv_queue.c |
| `vk_pipeline.h/c` | VkPipeline 기본 구조 | v3dv_pipeline.c |
| `vk_image.h/c` | VkImage | v3dv_image.c |

#### `src/vulkan/wsi/` - Window System Integration

**역할**: 플랫폼별 화면 출력 구현

**지원 플랫폼**:
- `wsi_common_wayland.c`: Wayland (Raspberry Pi OS 기본)
- `wsi_common_x11.c`: X11
- `wsi_common_display.c`: Direct-to-Display (KMS/DRM)
- `wsi_common_drm.c`: DRM 버퍼 공유

**V3DV 연동**: `v3dv_wsi.c`에서 `wsi_device` 초기화

---

### 2.6 커널 인터페이스: `include/drm-uapi/v3d_drm.h`

**역할**: Linux Kernel DRM 드라이버와의 IOCTL 계약

#### 주요 IOCTL

| IOCTL | 코드 | 구조체 | 사용처 |
|-------|------|--------|--------|
| `DRM_V3D_SUBMIT_CL` | 0x00 | `drm_v3d_submit_cl` | v3dv_queue.c:1040 |
| `DRM_V3D_SUBMIT_CSD` | 0x07 | `drm_v3d_submit_csd` | v3dv_queue.c:1154 |
| `DRM_V3D_SUBMIT_TFU` | 0x06 | `drm_v3d_submit_tfu` | v3dv_queue.c:1088 |
| `DRM_V3D_CREATE_BO` | 0x02 | `drm_v3d_create_bo` | v3dv_bo.c:249 |
| `DRM_V3D_MMAP_BO` | 0x03 | `drm_v3d_mmap_bo` | v3dv_bo.c:292 |
| `DRM_V3D_WAIT_BO` | 0x01 | `drm_v3d_wait_bo` | v3dv_bo.c:323 |

#### drm_v3d_submit_cl 구조체 분석

```c
struct drm_v3d_submit_cl {
   __u32 bcl_start;       // Binning CL 시작 주소
   __u32 bcl_end;         // Binning CL 끝 주소
   __u32 rcl_start;       // Rendering CL 시작 주소
   __u32 rcl_end;         // Rendering CL 끝 주소

   __u32 qma;             // Tile Allocation Memory 주소
   __u32 qms;             // Tile Allocation Memory 크기
   __u32 qts;             // Tile State 주소

   __u64 bo_handles;      // BO 핸들 배열 포인터
   __u32 bo_handle_count; // BO 개수

   __u64 extensions;      // drm_v3d_multi_sync 등
};
```

**동기화**: `drm_v3d_multi_sync` (타임라인 세마포어 지원)

---

## 3. 폴더 간 의존 관계 (데이터 흐름 중심)

### 3.1 Draw Call 전체 흐름

```
┌─────────────────────────────────────────────────────────┐
│ [1] Application: vkCmdDraw(cmdBuf, ...)                │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [2] src/vulkan/runtime/vk_command_buffer.c             │
│     - 공통 커맨드 버퍼 검증                              │
│     - 드라이버 후크 호출                                 │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [3] src/broadcom/vulkan/v3dv_cmd_buffer.c              │
│     - v3dv_CmdDraw() 구현                               │
│     - 파이프라인 바인딩 확인                             │
│     - 셰이더 유니폼 준비                                 │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [4] src/broadcom/vulkan/v3dv_cl.c                      │
│     - BCL 생성: 기하 정보 (vertex shader 실행)          │
│     - RCL 생성: 렌더링 정보 (fragment shader 실행)       │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [5] src/broadcom/cle/v3d_packet.xml 매크로 사용        │
│     cl_emit(&job->bcl, GL_SHADER_STATE, ...)           │
│     cl_emit(&job->rcl, TILE_RENDERING_MODE_CFG, ...)   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [6] Application: vkQueueSubmit(queue, ...)             │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [7] src/vulkan/runtime/vk_queue.c                      │
│     - 공통 큐 제출 로직                                  │
│     - 동기화 객체 처리                                   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [8] src/broadcom/vulkan/v3dv_queue.c                   │
│     handle_cl_job():                                    │
│       1. BO 리스트 수집 (v3dv_bo.c)                     │
│       2. drm_v3d_submit_cl 구조체 작성                  │
│       3. v3d_ioctl(DRM_IOCTL_V3D_SUBMIT_CL)            │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [9] include/drm-uapi/v3d_drm.h                         │
│     IOCTL 인터페이스                                     │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [10] Linux Kernel: drivers/gpu/drm/v3d/                │
│      v3d_submit_cl_ioctl():                             │
│        - BO 검증 및 GPU 주소 할당                        │
│        - Hardware Queue에 CL 추가                        │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [11] V3D GPU Hardware                                   │
│      Binning Phase:                                     │
│        - BCL 실행 → Vertex Shader                       │
│        - 타일별 프리미티브 분류                          │
│      Rendering Phase:                                   │
│        - RCL 실행 → Fragment Shader                     │
│        - 타일 메모리 렌더링 (64x64 픽셀)                 │
│      → IRQ 발생                                          │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [12] Kernel: IRQ Handler → syncobj 시그널               │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [13] src/vulkan/runtime/vk_sync.c                      │
│      Fence 시그널 처리                                   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [14] Application: vkWaitForFences() 완료               │
└─────────────────────────────────────────────────────────┘
```

### 3.2 셰이더 컴파일 흐름

```
┌─────────────────────────────────────────────────────────┐
│ [1] Application: vkCreateGraphicsPipeline()            │
│     - SPIR-V 셰이더 바이트코드 제공                      │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [2] src/broadcom/vulkan/v3dv_pipeline.c                │
│     - 파이프라인 상태 검증                               │
│     - 셰이더 컴파일 시작                                 │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [3] Mesa 공통: compiler/spirv/spirv_to_nir.c           │
│     SPIR-V → NIR (Mesa IR)                              │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [4] src/broadcom/compiler/v3d_nir_lower_*.c            │
│     NIR 최적화 패스 (V3D 특화)                           │
│     - v3d_nir_lower_io.c                                │
│     - v3d_nir_lower_image_load_store.c                  │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [5] src/broadcom/compiler/nir_to_vir.c (202KB)         │
│     NIR → VIR (V3D IR)                                  │
│     - 레지스터 할당 전 중간 표현                         │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [6] src/broadcom/compiler/vir_optimize.c               │
│     VIR 최적화                                           │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [7] src/broadcom/compiler/vir_to_qpu.c                 │
│     VIR → QPU 명령어                                     │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [8] src/broadcom/compiler/qpu_schedule.c (119KB)       │
│     레지스터 할당 & 명령어 스케줄링                      │
│     - QPU 파이프라인 최적화                              │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [9] src/broadcom/qpu/qpu_pack.c (98KB)                 │
│     QPU 명령어 바이너리 인코딩                           │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [10] QPU Machine Code → v3dv_pipeline 객체에 저장      │
│      Draw 시 BCL/RCL에서 참조                           │
└─────────────────────────────────────────────────────────┘
```

### 3.3 메모리 관리 흐름

```
┌─────────────────────────────────────────────────────────┐
│ [1] Application: vkAllocateMemory() / vkCreateBuffer() │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [2] src/broadcom/vulkan/v3dv_bo.c                      │
│     v3dv_bo_alloc():                                    │
│       1. BO 캐시 확인 (재사용 가능?)                     │
│       2. 캐시 미스 시 커널에 할당 요청                   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [3] v3d_ioctl(DRM_IOCTL_V3D_CREATE_BO)                 │
│     drm_v3d_create_bo { size, flags }                   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [4] Kernel: drivers/gpu/drm/v3d/v3d_bo.c               │
│     - GEM 객체 생성                                      │
│     - GPU 주소 할당                                      │
│     - 핸들 반환                                          │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [5] CPU 매핑 필요 시: v3dv_bo_map()                    │
│     v3d_ioctl(DRM_IOCTL_V3D_MMAP_BO)                   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ [6] 사용 완료: v3dv_bo_free()                          │
│     → BO 캐시에 반환 (즉시 해제 안 함)                   │
│     → 캐시 초과 시 실제 해제                             │
└─────────────────────────────────────────────────────────┘
```

---

## 4. V3D 하드웨어 아키텍처

### 4.1 Tile-Based Deferred Rendering (TBDR)

V3D는 **타일 기반 렌더러**로, 전통적인 즉시 모드 렌더러(Immediate Mode Renderer)와 다릅니다.

#### 렌더링 프로세스

```
[Binning Phase]
  1. Vertex Shader 실행 (모든 정점)
  2. 프리미티브를 타일별로 분류
     - 화면을 64×64 픽셀 타일로 분할
     - 각 타일에 어떤 삼각형이 그려질지 기록
  3. Tile Allocation Memory(QMA)에 저장
     - 타일별 작업 리스트 생성

[Rendering Phase]
  FOR EACH 타일:
    1. 타일 메모리 로드 (온칩 SRAM, 매우 빠름)
    2. 해당 타일의 프리미티브만 Fragment Shader 실행
    3. 블렌딩, 깊이 테스트 (모두 온칩에서 처리)
    4. 타일 메모리 → 메인 메모리 저장

[장점]
  - 메모리 대역폭 대폭 절감
  - Fragment Shader 오버드로우 최소화
  - 모바일 GPU에 최적화
```

#### BCL vs RCL

| Command List | 역할 | 실행 엔진 | 생성 위치 |
|--------------|------|-----------|----------|
| **BCL** (Binning CL) | Vertex Shader 실행<br>타일별 분류 | V3D_BIN | v3dv_cl.c |
| **RCL** (Rendering CL) | Fragment Shader 실행<br>픽셀 렌더링 | V3D_RENDER | v3dv_cl.c |

### 4.2 GPU 하드웨어 큐

```c
// include/drm-uapi/v3d_drm.h
enum v3d_queue {
   V3D_BIN,         // Binning 엔진
   V3D_RENDER,      // Rendering 엔진
   V3D_TFU,         // Texture Formatting Unit (포맷 변환)
   V3D_CSD,         // Compute Shader Dispatch
   V3D_CACHE_CLEAN, // 캐시 플러시
   V3D_CPU,         // CPU 작업 (간접 디스패치)
};
```

**동기화**:
- BCL → RCL 자동 동기화 (같은 submit)
- 다른 큐 간: syncobj 사용

---

## 5. 개발 워크플로우

### 5.1 빌드

```bash
# V3DV 드라이버만 빌드
meson setup build \
    -Dvulkan-drivers=broadcom \
    -Dgallium-drivers= \
    -Dplatforms=wayland,x11

ninja -C build

# 설치
sudo ninja -C build install
```

### 5.2 디버깅

```bash
# 커맨드 리스트 덤프
V3D_DEBUG=cl vkcube

# QPU 어셈블리 출력
V3D_DEBUG=qpu vkcube

# NIR 중간 코드
V3D_DEBUG=nir vkcube

# 조합 가능
V3D_DEBUG=cl,qpu,nir vkcube
```

### 5.3 성능 분석

```bash
# 성능 카운터
V3D_DEBUG=perf vkcube

# FPS 오버레이
VK_INSTANCE_LAYERS=VK_LAYER_MESA_overlay vkcube
```

---

## 6. 핵심 참조 파일 요약

| 목적 | 파일 경로 | 라인 수 |
|------|-----------|---------|
| 드라이버 진입점 | `src/broadcom/vulkan/v3dv_device.c` | 111KB |
| GPU 작업 제출 | `src/broadcom/vulkan/v3dv_queue.c` | - |
| 커맨드 기록 | `src/broadcom/vulkan/v3dv_cmd_buffer.c` | 176KB |
| CL 생성 | `src/broadcom/vulkan/v3dv_cl.c` | - |
| 메모리 관리 | `src/broadcom/vulkan/v3dv_bo.c` | - |
| 셰이더 컴파일 | `src/broadcom/compiler/nir_to_vir.c` | 202KB |
| 하드웨어 패킷 스펙 | `src/broadcom/cle/v3d_packet.xml` | 88KB |
| 커널 인터페이스 | `include/drm-uapi/v3d_drm.h` | - |
| QPU 명령어 | `src/broadcom/qpu/qpu_instr.h` | - |

---

## 7. 추가 리소스

### 공식 문서
- [Vulkan on Raspberry Pi](https://www.raspberrypi.com/documentation/computers/processors.html)
- [Mesa V3D Driver](https://docs.mesa3d.org/drivers/v3d.html)

### 하드웨어 스펙
- Raspberry Pi 4: BCM2711 (V3D 4.2)
- Raspberry Pi 5: BCM2712 (V3D 7.1)
- [Broadcom VideoCore VI](https://www.broadcom.com/)

### 커널 드라이버
- Linux Kernel: `drivers/gpu/drm/v3d/`
- DRM 서브시스템

---

## 라이선스

MIT License

Copyright © 2019 Raspberry Pi Ltd
Copyright © 2014-2018 Broadcom

---

**문서 버전**: 2.0
**작성일**: 2025-10-19
**Mesa 버전**: main branch
**대상 하드웨어**: Raspberry Pi 4, 5
