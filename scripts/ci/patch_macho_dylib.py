#!/usr/bin/env python3
import sys
import struct

def main():
    if len(sys.argv) < 2:
        print("Usage: patch_macho_dylib.py <path_to_binary>")
        sys.exit(1)
        
    path = sys.argv[1]
    with open(path, "r+b") as f:
        magic = struct.unpack("<I", f.read(4))[0]
        f.seek(0)
        if magic == 0xFEEDFACF:   # MH_MAGIC_64 (little-endian arm64)
            data = bytearray(f.read())
            # filetype is at offset 12 (after magic[4], cputype[4], cpusubtype[4])
            ft = struct.unpack_from("<I", data, 12)[0]
            if ft == 0x2:  # MH_EXECUTE
                struct.pack_into("<I", data, 12, 0x6)  # MH_DYLIB
                f.seek(0)
                f.write(data)
                print(f"Patched {path}: MH_EXECUTE -> MH_DYLIB")
            elif ft == 0x6:
                print(f"{path} already MH_DYLIB, skipping")
            else:
                print(f"Unexpected filetype 0x{ft:x} in {path}, skipping")
        elif magic == 0xBEBAFECA:  # FAT binary
            print("FAT binary detected — patching each slice")
            data = bytearray(f.read())
            nfat = struct.unpack_from(">I", data, 4)[0]
            for i in range(nfat):
                base = 8 + i * 20
                offset = struct.unpack_from(">I", data, base + 8)[0]
                sl_magic = struct.unpack_from("<I", data, offset)[0]
                if sl_magic == 0xFEEDFACF:
                    ft = struct.unpack_from("<I", data, offset + 12)[0]
                    if ft == 0x2:
                        struct.pack_into("<I", data, offset + 12, 0x6)
                        print(f"  Slice {i}: patched MH_EXECUTE -> MH_DYLIB")
            f.seek(0)
            f.write(data)
        else:
            print(f"Unknown magic 0x{magic:08x}, skipping patch")

if __name__ == "__main__":
    main()
