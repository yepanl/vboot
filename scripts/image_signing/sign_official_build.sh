#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Sign the final build image using the "official" keys.
#
# Prerequisite tools needed in the system path:
#
#  gbb_utility (from src/platform/vboot_reference)
#  vbutil_kernel (from src/platform/vboot_reference)
#  cgpt (from src/platform/vboot_reference)
#  dump_kernel_config (from src/platform/vboot_reference)
#  verity (from src/platform/verity)
#
# Usage: sign_for_ssd.sh <type> input_image /path/to/keys/dir output_image
# 
# where <type> is one of:
#               ssd  (sign an SSD image)
#               recovery (sign a USB recovery image)               
#               install (sign a factory install image) 

# Load common constants and variables.
. "$(dirname "$0")/common.sh"

if [ $# -ne 4 ]; then
  cat <<EOF
Usage: $0 <type> input_image /path/to/keys/dir output_image"
where <type> is one of:
             ssd  (sign an SSD image)
             recovery (sign a USB recovery image)               
             install (sign a factory install image) 
EOF
  exit 1
fi

# Abort on errors.
set -e

# Make sure the tools we need are available.
for prereqs in gbb_utility vbutil_kernel cgpt dump_kernel_config verity; do
  type -P "${prereqs}" &>/dev/null || \
    { echo "${prereqs} tool not found."; exit 1; }
done

TYPE=$1
INPUT_IMAGE=$2
KEY_DIR=$3
OUTPUT_IMAGE=$4

# Re-calculate rootfs hash, update rootfs and kernel command line.
# Args: IMAGE KEYBLOCK PRIVATEKEY
recalculate_rootfs_hash() {
  local image=$1  # Input image.
  local keyblock=$2  # Keyblock for re-generating signed kernel partition
  local signprivate=$3  # Private key to use for signing.

  # First, grab the existing kernel partition and get the kernel config.
  temp_kimage=$(make_temp_file)
  extract_image_partition ${image} 2 ${temp_kimage}
  local kernel_config=$(sudo dump_kernel_config ${temp_kimage})
  local dm_config=$(echo $kernel_config |
    sed -e 's/.*dm="\([^"]*\)".*/\1/g' |
    cut -f2- -d,)
  # We extract dm=... portion of the config command line. Here's an example:
  #
  # dm="0 2097152 verity ROOT_DEV HASH_DEV 2097152 1 \
  # sha1 63b7ad16cb9db4b70b28593f825aa6b7825fdcf2"
  #

  if [ -z ${dm_config} ]; then
    echo "WARNING: Couldn't grab dm_config. Aborting rootfs hash calculation"
    return
  fi
  local rootfs_sectors=$(echo ${dm_config} | cut -f2 -d' ')
  local root_dev=$(echo ${dm_config} | cut -f4 -d ' ')
  local hash_dev=$(echo ${dm_config} | cut -f5 -d ' ')
  local verity_depth=$(echo ${dm_config} | cut -f7 -d' ')
  local verity_algorithm=$(echo ${dm_config} | cut -f8 -d' ')

  # Mount the rootfs and run the verity tool on it.
  local hash_image=$(make_temp_file)
  local rootfs_img=$(make_temp_file)
  extract_image_partition ${image} 3 ${rootfs_img}
  local table="vroot none ro,"$(sudo verity create \
    ${verity_depth} \
    ${verity_algorithm} \
    ${rootfs_img} \
    $((rootfs_sectors / 8)) \
    ${hash_image})
  # Reconstruct new kernel config command line and replace placeholders.
  table="$(echo "$table" |
    sed -s "s|ROOT_DEV|${root_dev}|g;s|HASH_DEV|${hash_dev}|")"
  kernel_config=$(echo ${kernel_config} |
    sed -e 's#\(.*dm="\)\([^"]*\)\(".*\)'"#\1${table}\3#g")

  # Overwrite the appended hashes in the rootfs
  local temp_config=$(make_temp_file)
  echo ${kernel_config} >${temp_config}
  dd if=${hash_image} of=${rootfs_img} bs=512 \
    seek=${rootfs_sectors} conv=notrunc

  # Re-calculate kernel partition signature and command line.
  local updated_kimage=$(make_temp_file)
  vbutil_kernel --repack ${updated_kimage} \
    --keyblock ${keyblock} \
    --signprivate ${signprivate} \
    --oldblob ${temp_kimage} \
    --config ${temp_config}
  
  replace_image_partition ${image} 2 ${updated_kimage}
  replace_image_partition ${image} 3 ${rootfs_img}
}

# Extracts the firmware update binaries from the a firmware update
# shell ball (generated by src/platform/firmware/pack_firmware.sh)
# Args: INPUT_SCRIPT OUTPUT_DIR
get_firmwarebin_from_shellball() {
  local input=$1
  local output_dir=$2  
  uudecode -o - ${input} | tar -C ${output_dir} -zxf - 2>/dev/null || \
    echo "Extracting firmware autoupdate failed.
Try re-running with FW_NOUPDATE=1." && exit 1
}

# Re-sign the firmware AU payload inside the image rootfs with a new keys.
# Args: IMAGE
resign_firmware_payload() {
  local image=$1

  # Grab firmware image from the autoupdate shellball.
  local rootfs_dir=$(make_temp_dir)
  mount_image_partition ${image} 3 ${rootfs_dir}
  
  local shellball_dir=$(make_temp_dir)
  get_firmwarebin_from_shellball \
    ${rootfs_dir}/usr/sbin/chromeos-firmwareupdate ${shellball_dir}

  temp_outfd=$(make_temp_file)
  # Replace the root key in the GBB
  # TODO(gauravsh): Remove when we lock down the R/O portion of firmware.
  gbb_utility -s \
    --rootkey=${KEY_DIR}/root_key.vbpubk \
    --recoverykey=${KEY_DIR}/recovery_key.vbpubk \
    ${shellball_dir}/bios.bin ${temp_outfd}

  # Resign the firmware with new keys
  ${SCRIPT_DIR}/resign_firmwarefd.sh ${temp_outfd} ${temp_dir}/bios.bin \
    ${KEY_DIR}/firmware_data_key.vbprivk \
    ${KEY_DIR}/firmware.keyblock \
    ${KEY_DIR}/kernel_subkey.vbpubk

  # Replace MD5 checksum in the firmware update payload
  newfd_checksum=$(md5sum ${shellball_dir}/bios.bin | cut -f 1 -d ' ')
  temp_version=$(make_temp_file)
  cat ${shellball_dir}/VERSION | 
  sed -e "s#\(.*\)\ \(.*bios.bin.*\)#${newfd_checksum}\ \2#" > ${temp_version}
  sudo cp ${temp_version} ${shellball_dir}/VERSION

  # Re-generate firmware_update.tgz and copy over encoded archive in
  # the original shell ball.
  new_fwblob=$(make_temp_file)
  tar zcf - -C ${shellball_dir} . | \
    uuencode firmware_package.tgz > ${new_fwblob}
  new_shellball=$(make_temp_file)
  cat ${rootfs_dir}/usr/sbin/chromeos-firmwareupdate | \
    sed -e '/^begin .*firmware_package/,/end/D' | \
    cat - ${new_fwblob} >${new_shellball}
  sudo cp ${new_shellball} ${rootfs_dir}/usr/sbin/chromeos-firmwareupdate
  # Force unmount of the image as it is needed later.
  sudo umount -d ${rootfs_dir}
  echo "Re-signed firmware AU payload in $image"
}

# Generate the SSD image
sign_for_ssd() {
  ${SCRIPT_DIR}/resign_image.sh ${INPUT_IMAGE} ${OUTPUT_IMAGE} \
    ${KEY_DIR}/kernel_data_key.vbprivk \
    ${KEY_DIR}/kernel.keyblock
  echo "Output signed SSD image to ${OUTPUT_IMAGE}"
}

# Generate the USB (recovery + install) image
sign_for_recovery() {
  ${SCRIPT_DIR}/resign_image.sh ${INPUT_IMAGE} ${OUTPUT_IMAGE} \
    ${KEY_DIR}/recovery_kernel_data_key.vbprivk \
    ${KEY_DIR}/recovery_kernel.keyblock 

  # Now generate the installer vblock with the SSD keys.
  temp_kimage=$(make_temp_file)
  temp_out_vb=$(make_temp_file)
  extract_image_partition ${OUTPUT_IMAGE} 2 ${temp_kimage}
  ${SCRIPT_DIR}/resign_kernel_partition.sh ${temp_kimage} ${temp_out_vb} \
    ${KEY_DIR}/kernel_data_key.vbprivk \
    ${KEY_DIR}/kernel.keyblock

  # Copy the installer vblock to the stateful partition.
  local stateful_dir=$(make_temp_dir)
  mount_image_partition ${OUTPUT_IMAGE} 1 ${stateful_dir}
  sudo cp ${temp_out_vb} ${stateful_dir}/vmlinuz_hd.vblock

  echo "Output signed recovery image to ${OUTPUT_IMAGE}"
}

# Generate the factory install image.
sign_for_factory_install() {
  ${SCRIPT_DIR}/resign_image.sh ${INPUT_IMAGE} ${OUTPUT_IMAGE} \
    ${KEY_DIR}/recovery_kernel_data_key.vbprivk \
    ${KEY_DIR}/installer_kernel.keyblock
  echo "Output signed factory install image to ${OUTPUT_IMAGE}"
}

# Firmware payload signing hidden behind a flag until it actually makes
# it into the image.
if [ ! "${FW_UPDATE}" == "1" ]; then
  resign_firmware_payload ${INPUT_IMAGE}
fi

if [ "${TYPE}" == "ssd" ]; then
  recalculate_rootfs_hash ${INPUT_IMAGE} \
    ${KEY_DIR}/kernel.keyblock \
    ${KEY_DIR}/kernel_data_key.vbprivk
  sign_for_ssd
elif [ "${TYPE}" == "recovery" ]; then
  recalculate_rootfs_hash ${INPUT_IMAGE} \
    ${KEY_DIR}/recovery_kernel.keyblock \
    ${KEY_DIR}/recovery_kernel_data_key.vbprivk
  sign_for_recovery
elif [ "${TYPE}" == "install" ]; then
  recalculate_rootfs_hash ${INPUT_IMAGE} \
    ${KEY_DIR}/installer_kernel.keyblock \
    ${KEY_DIR}/recovery_kernel_data_key.vbprivk
  sign_for_factory_install
else
  echo "Invalid type ${TYPE}"
  exit 1
fi
