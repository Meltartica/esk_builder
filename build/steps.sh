# shellcheck shell=bash
# shellcheck disable=SC2164,SC2153

################################################################################
# Build steps
################################################################################

init_build() {
    step 1 "Init build"

    BUILD_TAG="kernel_$(hexdump -v -e '/1 "%02x"' -n4 /dev/urandom)"
    info "Build tag generated: $BUILD_TAG"

    # Kernel flavour
    KSU="$(norm_bool "${KSU:-false}")"
    SUSFS="$(norm_bool "${SUSFS:-false}")"

    # Make arguments
    MAKE_ARGS=(
        -j"$JOBS" O="$KERNEL_OUT" ARCH="arm64"
        CC="ccache clang" CROSS_COMPILE="aarch64-linux-gnu-"
        LLVM="1" LD="$CLANG_BIN/ld.lld"
    )

    # Environment default setting
    if is_ci; then
        RESET_SOURCES="$(norm_default "${RESET_SOURCES-}" "true")"
    else
        RESET_SOURCES="$(norm_default "${RESET_SOURCES-}" "false")"
    fi

    info "Mode: $(is_ci && echo CI || echo local)"

    # Set timezone
    export TZ="$TIMEZONE"
}

init_logging() {
    # Clean logfile before writing
    : > "$LOGFILE"

    exec > >(tee -a "$LOGFILE") 2>&1
    step 2 "Init logging"
}

validate_env() {
    step 3 "Validate environment"
    info "Validating environment variables..."
    if [[ -z ${GH_TOKEN:-} ]]; then
        if [[ -x "$CLANG_BIN/clang" ]]; then
            :
        elif is_ci; then
            error "Required Github PAT missing: GH_TOKEN"
        else
            warn "GH_TOKEN not set. Github requests may be rate-limited."
        fi
    fi

    # Config checks
    if is_true "$SUSFS" && ! is_true "$KSU"; then
        error "Cannot use SUSFS without KernelSU"
    fi
}

prepare_dirs() {
    step 5 "Prepare directories"

    local out_dir_list=(
        "$OUT_DIR" "$BOOT_IMAGE" "$ANYKERNEL"
    )
    local src_dir_list=(
        "$KERNEL" "$BUILD_TOOLS"
        "$MKBOOTIMG" "$SUSFS_DIR"
    )

    info "Resetting output directories: $(printf '%s ' "${out_dir_list[@]##*/}")"
    for dir in "${out_dir_list[@]}"; do
        reset_dir "$dir"
    done

    if is_true "$RESET_SOURCES"; then
        info "Resetting source directories: $(printf '%s ' "${src_dir_list[@]##*/}")"
        for dir in "${src_dir_list[@]}"; do
            reset_dir "$dir"
        done
    fi
}

fetch_sources() {
    step 6 "Fetch sources"

    info "Cloning kernel source..."
    git_clone "$KERNEL_REPO" "$KERNEL"

    info "Cloning AnyKernel3..."
    git_clone "$ANYKERNEL_REPO" "$ANYKERNEL"

    info "Cloning build tools..."
    git_clone "$BUILD_TOOLS_REPO" "$BUILD_TOOLS"
    git_clone "$MKBOOTIMG_REPO" "$MKBOOTIMG"
}

setup_toolchain() {
    step 7 "Setup toolchain"

    _use_toolchain() {
        export PATH="$CLANG_BIN:$PATH"
        COMPILER_STRING="$("$CLANG_BIN/clang" --version | head -n 1 | sed 's/(https..*//')"
        export KBUILD_BUILD_USER KBUILD_BUILD_HOST
    }

    if [[ -x "$CLANG_BIN/clang" ]]; then
        info "Using existing AOSP Clang toolchain"
        _use_toolchain
        return 0
    fi

    info "Fetching AOSP Clang toolchain"
    local clang_url
    local auth_header=()
    [[ -n ${GH_TOKEN:-} ]] && auth_header=(-H "Authorization: Bearer $GH_TOKEN")
    clang_url=$(curl -fsSL "https://api.github.com/repos/bachnxuan/aosp_clang_mirror/releases/latest" \
        "${auth_header[@]}" \
        | grep "browser_download_url" \
        | grep ".tar.gz" \
        | cut -d '"' -f 4)

    mkdir -p "$CLANG"

    local attempt=0
    local retries=5
    local aria_opts=(
        -q -c -x16 -s16 -k8M
        --file-allocation=falloc --check-certificate=false
        -d "$WORKSPACE" -o "clang-archive" "$clang_url"
    )

    while ((attempt < retries)); do
        if aria2c "${aria_opts[@]}"; then
            success "Clang download successful!"
            break
        fi

        ((attempt++))
        warn "Clang download attempt $attempt/$retries failed, retrying..."
        ((attempt < retries)) && sleep 5
    done

    if ((attempt == retries)); then
        error "Clang download failed after $retries attempts!"
    fi

    tar -xzf "$WORKSPACE/clang-archive" -C "$CLANG"
    rm -f "$WORKSPACE/clang-archive"

    _use_toolchain
}

apply_susfs() {
    info "Apply SuSFS kernel-side patches"

    local susfs_dir="$SUSFS_DIR"
    local susfs_patches="$susfs_dir/kernel_patches"

    git_clone "$SUSFS_REPO" "$susfs_dir"
    cp -R "$susfs_patches"/fs/* ./fs
    cp -R "$susfs_patches"/include/* ./include

    patch -s -p1 --fuzz=3 --no-backup-if-mismatch < "$susfs_patches"/50_add_susfs_in_gki-android*-*.patch
    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')

    config --enable CONFIG_KSU_SUSFS
    config --enable CONFIG_KSU_SUSFS_SUS_PATH
    config --enable CONFIG_KSU_SUSFS_SUS_KSTAT
    config --enable CONFIG_KSU_SUSFS_OPEN_REDIRECT

    success "SuSFS applied!"
}

prepare_build() {
    step 8 "Prepare build"

    cd "$KERNEL"

    # Defconfig existence check
    local defconfig_file="$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG"
    [[ -f $defconfig_file ]] || error "Defconfig not found: $KERNEL_DEFCONFIG"

    if is_true "$KSU"; then
        info "Setup KernelSU"
        install_ksu "KOWX712/KernelSU" "staging"
        config --enable CONFIG_KSU
        success "KernelSU added"
    fi

    # SuSFS
    if is_true "$SUSFS"; then
        apply_susfs
    else
        config --disable CONFIG_KSU_SUSFS
    fi

    # Config Clang LTO
    clang_lto "$CLANG_LTO"
}

build_kernel() {
    step 9 "Build kernel"

    cd "$KERNEL"

    info "Generate defconfig: $KERNEL_DEFCONFIG"
    make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG" > /dev/null 2>&1

    info "Building Image..."
    make "${MAKE_ARGS[@]}" Image
    success "Kernel built successfully"

    KERNEL_VERSION=$(make -s kernelversion | cut -d- -f1)
}

package_anykernel() {
    step 10 "Package AnyKernel3"

    local package_name="$1"

    pushd "$ANYKERNEL" > /dev/null
    cp -p "$KERNEL_OUT/arch/arm64/boot/Image" .

    info "Compressing kernel image using zstd..."
    zstd -19 -T0 --no-progress -o Image.zst Image > /dev/null 2>&1
    rm -f ./Image
    sha256sum Image.zst > Image.zst.sha256

    zip -r9q -T -X -y -n .zst "$OUT_DIR/$package_name-AnyKernel3.zip" . -x '.git/*' '*.log'

    popd > /dev/null
    success "AnyKernel3 packaged"
}

package_bootimg() {
    step 11 "Package boot image"

    local package_name="$1"
    local partition_size=$((64 * 1024 * 1024))

    pushd "$BOOT_IMAGE" > /dev/null

    cp -p "$KERNEL_OUT/arch/arm64/boot/Image" ./Image
    gzip -n -k -f -9 Image
    lz4 -f -l --favor-decSpeed Image Image.lz4

    curl -fsSLo gki-kernel.zip "$GKI_URL"
    unzip gki-kernel.zip > /dev/null 2>&1 && rm gki-kernel.zip

    "$MKBOOTIMG/unpack_bootimg.py" --boot_img="boot-5.10.img"

    "$MKBOOTIMG/mkbootimg.py" \
        --header_version "4" \
        --kernel Image \
        --output boot-raw.img \
        --ramdisk out/ramdisk \
        --os_version "12.0.0" \
        --os_patch_level "2025-09"
    "$BUILD_TOOLS/linux-x86/bin/avbtool" add_hash_footer \
        --partition_name boot \
        --partition_size "$partition_size" \
        --image boot-raw.img \
        --algorithm SHA256_RSA4096 \
        --key "$BOOT_SIGN_KEY"

    "$MKBOOTIMG/mkbootimg.py" \
        --header_version "4" \
        --kernel Image.gz \
        --output boot-gz.img \
        --ramdisk out/ramdisk \
        --os_version "12.0.0" \
        --os_patch_level "2025-09"
    "$BUILD_TOOLS/linux-x86/bin/avbtool" add_hash_footer \
        --partition_name boot \
        --partition_size "$partition_size" \
        --image boot-gz.img \
        --algorithm SHA256_RSA4096 \
        --key "$BOOT_SIGN_KEY"

    "$MKBOOTIMG/mkbootimg.py" \
        --header_version "4" \
        --kernel Image.lz4 \
        --output boot-lz4.img \
        --ramdisk out/ramdisk \
        --os_version "12.0.0" \
        --os_patch_level "2025-09"
    "$BUILD_TOOLS/linux-x86/bin/avbtool" add_hash_footer \
        --partition_name boot \
        --partition_size "$partition_size" \
        --image boot-lz4.img \
        --algorithm SHA256_RSA4096 \
        --key "$BOOT_SIGN_KEY"

    cp "$BOOT_IMAGE/boot-raw.img" "$OUT_DIR/$package_name-boot-raw.img"
    cp "$BOOT_IMAGE/boot-gz.img" "$OUT_DIR/$package_name-boot-gz.img"
    cp "$BOOT_IMAGE/boot-lz4.img" "$OUT_DIR/$package_name-boot-lz4.img"

    popd > /dev/null
}

write_metadata() {
    step 12 "Write metadata"

    local package_name="$1"
    cat > "$GITHUB_ENV_FILE" << EOF
kernel_version=$KERNEL_VERSION
kernel_name=$KERNEL_NAME
toolchain=$COMPILER_STRING
package_name=$package_name
variant=$VARIANT
name=$KERNEL_NAME
out_dir=$OUT_DIR
release_repo=$RELEASE_REPO
release_branch=$RELEASE_BRANCH
EOF
}