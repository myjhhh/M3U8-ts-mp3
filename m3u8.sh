#!/bin/bash
# merge_extract_convert_segments.sh - 解析本地m3u8→复制原命名TS→转同名MP3→删除TS
# 新增：自动检测系统并安装FFmpeg

# ========== 步骤0：自动检测系统并安装FFmpeg ==========
# 检查FFmpeg是否已安装
if ! command -v ffmpeg &> /dev/null; then
  echo "⚠️  未检测到FFmpeg，开始自动检测系统并安装..."
  
  # 检测系统发行版
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
  elif type lsb_release &> /dev/null; then
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
  elif [ -f /etc/redhat-release ]; then
    OS=$(cat /etc/redhat-release | cut -d' ' -f1)
  else
    echo "❌ 错误：无法识别你的Linux发行版，请手动安装FFmpeg！"
    exit 1
  fi

  # 根据系统类型执行安装命令
  case "$OS" in
    "Ubuntu"|"Debian"|"Deepin"|"Kali GNU/Linux")
      echo "🔧 检测到Debian/Ubuntu系系统，开始安装FFmpeg..."
      sudo apt update -y && sudo apt install ffmpeg -y
      ;;
    "CentOS Linux"|"CentOS"|"Red Hat Enterprise Linux"|"RHEL")
      echo "🔧 检测到CentOS/RHEL系系统，开始配置源并安装FFmpeg..."
      # CentOS 7
      if [[ "$VER" == "7" ]]; then
        sudo yum install epel-release -y
        sudo rpm -ivh https://download1.rpmfusion.org/free/el/rpmfusion-free-release-7.noarch.rpm
        sudo yum install ffmpeg -y
      # CentOS 8/RHEL 8
      elif [[ "$VER" == "8" ]]; then
        sudo dnf install https://download1.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm -y
        sudo dnf install ffmpeg -y
      # CentOS 9/RHEL 9
      elif [[ "$VER" == "9" ]]; then
        sudo dnf install https://download1.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm -y
        sudo dnf install ffmpeg -y
      fi
      ;;
    "Fedora")
      echo "🔧 检测到Fedora系统，开始安装FFmpeg..."
      sudo dnf install ffmpeg -y
      ;;
    "Arch Linux"|"Manjaro Linux")
      echo "🔧 检测到Arch/Manjaro系统，开始安装FFmpeg..."
      sudo pacman -S ffmpeg --noconfirm
      ;;
    *)
      echo "❌ 错误：暂不支持自动安装该系统的FFmpeg（$OS），请手动安装！"
      exit 1
      ;;
  esac

  # 验证安装结果
  if command -v ffmpeg &> /dev/null; then
    echo "✅ FFmpeg安装成功！"
  else
    echo "❌ FFmpeg自动安装失败，请手动安装后重试！"
    exit 1
  fi
else
  echo "✅ 检测到FFmpeg已安装，继续执行脚本..."
fi

# ========== 步骤1：用户输入路径并校验 ==========
# 提示用户输入M3U8文件路径（源路径）
read -p "请输入本地M3U8文件的完整路径（例如：/home/root/my_video/playlist.m3u8）：" M3U8_FILE
# 校验M3U8文件是否存在
if [ ! -f "$M3U8_FILE" ]; then
  echo "❌ 错误：指定的M3U8文件不存在，请检查路径是否正确！"
  exit 1
fi

# 提示用户输入分片保存的目标路径（输出路径）
read -p "请输入分片保存的目标文件夹完整路径（例如：/home/root/my_video/segments）：" TARGET_DIR

# 创建目标文件夹（若不存在）
mkdir -p "$TARGET_DIR"
if [ ! -d "$TARGET_DIR" ]; then
  echo "❌ 错误：目标文件夹创建失败，请检查路径权限或格式！"
  exit 1
fi

# ========== 步骤2：解析M3U8，提取分片完整路径 ==========
# 获取m3u8文件所在目录（用于拼接相对路径）
M3U8_DIR=$(dirname "$M3U8_FILE")

# 提取非注释、非空行的分片路径（临时文件）
grep -v "^#" "$M3U8_FILE" | grep -v "^$" > temp_segments.txt

# 拼接完整路径并写入目标文件（同时记录源文件名）
> segments_local.txt  # 清空原有内容
while read line; do
  if [[ "$line" = /* ]]; then
    # 绝对路径：直接保留完整路径
    echo "$line" >> segments_local.txt
  else
    # 相对路径：拼接M3U8所在目录得到完整路径
    echo "$M3U8_DIR/$line" >> segments_local.txt
  fi
done < temp_segments.txt

# 删除临时文件
rm temp_segments.txt

segment_count=$(wc -l < segments_local.txt)
echo "✅ 已从M3U8解析出 $segment_count 个分片路径，开始复制..."

# ========== 步骤3：批量复制分片到目标目录（保留源文件名） ==========
success_count=0
fail_count=0
while read seg_full_path; do
  # 提取源文件的原始文件名（例如：/a/b/123.ts → 123.ts）
  seg_filename=$(basename "$seg_full_path")
  
  if [ -f "$seg_full_path" ]; then
    # 复制文件到目标文件夹（保留原始文件名）
    cp "$seg_full_path" "$TARGET_DIR/$seg_filename"
    echo "✅ 已复制：$seg_filename (原路径：$seg_full_path)"
    success_count=$((success_count+1))
  else
    echo "⚠️  跳过：文件不存在 $seg_full_path"
    fail_count=$((fail_count+1))
  fi
done < segments_local.txt

# ========== 步骤4：批量将TS文件转换为同名MP3并删除原TS ==========
echo -e "\n🔄 开始将TS文件转换为MP3格式（转换后删除原TS）..."
convert_success=0
convert_fail=0

# 遍历目标文件夹中的所有TS文件（只处理复制成功的TS）
for ts_file in "$TARGET_DIR"/*.ts; do
  # 检查是否存在匹配的TS文件（避免空遍历）
  if [ -f "$ts_file" ]; then
    # 提取TS文件名（不含路径），生成同名MP3路径
    ts_filename=$(basename "$ts_file")
    mp3_filename="${ts_filename%.ts}.mp3"
    mp3_file="$TARGET_DIR/$mp3_filename"

    # 使用FFmpeg转换为MP3（128k音质，禁用视频流）
    # 屏蔽FFmpeg冗余输出，只保留错误信息
    ffmpeg -i "$ts_file" -vn -acodec mp3 -b:a 128k -y "$mp3_file" > /dev/null 2>&1

    # 检查转换是否成功：MP3文件存在则删除原TS
    if [ -f "$mp3_file" ]; then
      rm -f "$ts_file"  # 删除原TS文件
      echo "✅ 已转换并删除TS：$mp3_filename (源文件：$ts_filename)"
      convert_success=$((convert_success+1))
    else
      echo "❌ 转换失败：$ts_filename（保留原TS文件）"
      convert_fail=$((convert_fail+1))
    fi
  fi
done

# ========== 结束清理 & 结果汇总 ==========
rm -f segments_local.txt  # 删除分片路径临时文件
echo -e "\n===== 操作完成 ======"
echo "📁 目标文件夹：$TARGET_DIR"
echo "🔍 分片复制结果："
echo "  ✅ 成功复制：$success_count 个TS分片（保留原文件名）"
echo "  ❌ 失败/跳过：$fail_count 个分片"
echo "🔍 MP3转换结果："
echo "  ✅ 成功转换：$convert_success 个MP3文件（已删除对应TS）"
echo "  ❌ 转换失败：$convert_fail 个文件（保留原TS）"
echo -e "\n💡 最终保留的文件：$TARGET_DIR 下的所有.mp3文件"