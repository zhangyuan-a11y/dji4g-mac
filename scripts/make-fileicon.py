#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给文件或文件夹挂上 Finder 自定义图标。

用来干什么：
  客户解压后看到的「双击安装.command」原先是一个白色空白方块（.command 的默认
  图标），一眼看不出这是安装程序。Finder 的自定义图标不在文件里，它存在两个
  扩展属性上：`com.apple.ResourceFork`（一份 icns 资源）和 `com.apple.FinderInfo`
  （第 9 个字节的 kHasCustomIcon 位）。macOS 没有命令行工具做这件事，所以这里
  按资源分叉的老格式自己拼一份。

用法：
  make-fileicon.py <图标.icns> <目标路径> [目标路径...]
"""

import ctypes
import ctypes.util
import os
import struct
import sys

RES_TYPE = b"icns"
RES_ID = 128
RES_DATA_OFFSET = 256      # 资源数据必须落在数据区第 256 字节之后，老格式的规矩
FN_HAS_CUSTOM_ICON = 0x04


def resource_fork(icns):
    """把一份 icns 包成单资源的资源分叉。"""
    entry = struct.pack(">I", len(icns)) + icns
    entry += b"\0" * ((2 - len(entry) % 2) % 2)          # 长度字段按偶对齐
    data_len = RES_DATA_OFFSET + len(entry)

    type_list = struct.pack(">H", 0)                      # 资源类型数 - 1
    type_list += RES_TYPE + struct.pack(">H", 0)          # 该类型的资源数 - 1
    type_list += struct.pack(">H", 2 + 8)                 # 该类型引用表在类型表里的偏移
    ref = struct.pack(">H", RES_ID) + b"\xff\xff" + b"\x00" + b"\x00\x01\x00"
    map_len = 16 + 4 + 2 + 2 + 2 + 2 + len(type_list) + len(ref)

    header = struct.pack(">IIII", 16, 16 + data_len, data_len, map_len)
    body = b"\0" * RES_DATA_OFFSET + entry
    # 资源映射表：前 16 字节是头部的副本，后面才是类型表/引用表/名字表。
    map_ = header + struct.pack(">IHHHH", 0, 0, 0, 28, 28 + len(type_list) + len(ref))
    map_ += type_list + ref
    assert len(map_) == map_len, (len(map_), map_len)
    return header + body + map_


# 扩展属性得走 libc：python 的 os.setxattr 只有 Linux 版，macOS 上一直没实现，
# 而 xattr(1) 只能收字符串/十六进制，几十万字节的图标塞不进命令行。
_LIBC = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_LIBC.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                           ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
_LIBC.setxattr.restype = ctypes.c_int


def set_xattr(target, name, value):
    buf = ctypes.create_string_buffer(value, len(value))
    if _LIBC.setxattr(target.encode("utf-8"), name.encode("utf-8"), buf,
                      len(value), 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), target)


def get_xattr(target, name):
    size = _LIBC.getxattr(target.encode("utf-8"), name.encode("utf-8"), None, 0, 0, 0)
    if size < 0:
        return None
    buf = ctypes.create_string_buffer(size)
    got = _LIBC.getxattr(target.encode("utf-8"), name.encode("utf-8"), buf, size, 0, 0)
    if got < 0:
        return None
    return buf.raw[:got]


def apply(icns_path, target):
    with open(icns_path, "rb") as fh:
        icns = fh.read()
    set_xattr(target, "com.apple.ResourceFork", resource_fork(icns))
    info = bytearray((get_xattr(target, "com.apple.FinderInfo") or b"").ljust(32, b"\0"))
    info[8] |= FN_HAS_CUSTOM_ICON
    set_xattr(target, "com.apple.FinderInfo", bytes(info))
    os.utime(target, None)          # 让 Finder 重新读一遍图标


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip())
        return 2
    icns, targets = sys.argv[1], sys.argv[2:]
    for target in targets:
        if not os.path.exists(target):
            print("跳过（不存在）：%s" % target)
            continue
        apply(icns, target)
        print("已设图标：%s" % target)
    return 0


_LIBC.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                           ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
_LIBC.getxattr.restype = ctypes.c_ssize_t


if __name__ == "__main__":
    sys.exit(main())
