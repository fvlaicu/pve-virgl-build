#!/usr/bin/env bash
# The license texts in licenses/<origin>/, one bin/collect-licenses line per library in the bundle
# (Alpine 3.22, collected 2026-10-27). Each file was picked from `bin/collect-licenses list <origin>`;
# the paths name versions, so after an update a line fails until its paths are edited.
#   licenses/collect-all.sh            all of them again
# Which file covers which library:
#   gcc: libstdc++ and libgcc are GPL-3.0 with the GCC runtime library exception; Alpine labels the
#     origin GPL-2.0-or-later AND LGPL-2.1-or-later, so all five top-level license files.
#   elfutils: libelf is GPL-2.0-or-later OR LGPL-3.0-or-later (COPYING is GPL-3.0, the tools').
#   llvm20: libLLVM's own LICENSE.TXT. mesa: docs/license.rst (the Rust crates in its source are
#   build-time only). zstd: BSD (LICENSE) or GPL-2.0 (COPYING). xz: liblzma is 0BSD; COPYING says
#   which part is under which, so all of them.
#   libdrm has no license file: the notices of the three libraries the bundle carries, from the
#   headers of their main files (libdrm.so.2, libdrm_amdgpu.so.1, libdrm_intel.so.1).
set -euo pipefail
c=$(dirname "$(readlink -f "$0")")/../bin/collect-licenses
"$c" get libbsd libbsd-0.12.2/COPYING
"$c" get libdrm drm-libdrm-2.4.124/xf86drm.c:9-32 drm-libdrm-2.4.124/amdgpu/amdgpu_device.c:1-22 drm-libdrm-2.4.124/intel/intel_bufmgr.c:1-26
"$c" get elfutils elfutils-0.193/COPYING elfutils-0.193/COPYING-GPLV2 elfutils-0.193/COPYING-LGPLV3
"$c" get expat expat-2.9.0/COPYING
"$c" get libffi libffi-3.4.8/LICENSE
"$c" get gcc gcc-14.2.0/COPYING gcc-14.2.0/COPYING.LIB gcc-14.2.0/COPYING3 gcc-14.2.0/COPYING3.LIB gcc-14.2.0/COPYING.RUNTIME
"$c" get libmd libmd-1.1.0/COPYING
"$c" get libpciaccess libpciaccess-0.18.1/COPYING
"$c" get libva libva-2.22.0/COPYING
"$c" get libx11 libX11-1.8.11/COPYING
"$c" get libxau libXau-1.0.12/COPYING
"$c" get libxcb libxcb-1.17.0/COPYING
"$c" get libxdmcp libXdmcp-1.1.5/COPYING
"$c" get libxml2 libxml2-2.13.9/Copyright
"$c" get libxshmfence libxshmfence-1.3.3/COPYING
"$c" get llvm20 llvm-project-20.1.8.src/llvm/LICENSE.TXT
"$c" get mesa mesa-25.1.9/docs/license.rst
"$c" get musl musl-1.2.5/COPYRIGHT
"$c" get spirv-tools SPIRV-Tools-vulkan-sdk-1.4.313.0/LICENSE
"$c" get xz xz-5.8.4/COPYING xz-5.8.4/COPYING.0BSD xz-5.8.4/COPYING.GPLv2 xz-5.8.4/COPYING.GPLv3 xz-5.8.4/COPYING.LGPLv2.1
"$c" get zlib zlib-1.3.2/LICENSE
"$c" get zstd zstd-1.5.7/LICENSE zstd-1.5.7/COPYING
