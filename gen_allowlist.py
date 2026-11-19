import os, struct, sys

MAGIC = 0x7F4B5355
FILE_VER = 4
PROFILE_VER = 4
REC_SIZE = 784  # 0x310

def make_profile(pkg: str, uid: int) -> bytearray:
    rec = bytearray(REC_SIZE)
    struct.pack_into("<I", rec, 0x000, PROFILE_VER)        # version = 4
    key = pkg.encode("utf-8")[:255]
    rec[0x004:0x004 + len(key)] = key                      # key[256]
    struct.pack_into("<i", rec, 0x104, uid)                # current_uid
    rec[0x108] = 1                                         # allow_su = true
    rec[0x110] = 1                                         # rp_config.use_default = true
    # Default trailing metadata matching 35171/4 Manager serialization
    struct.pack_into("<I", rec, 0x218, 1)
    struct.pack_into("<Q", rec, 0x2A8, 0x000001FFFFFFFFFF)
    struct.pack_into("<I", rec, 0x2C0, 0x30)
    struct.pack_into("<I", rec, 0x300, 2)
    struct.pack_into("<I", rec, 0x308, 1)
    return rec

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <path> <pkg:uid> [...]")
        sys.exit(1)
    path = sys.argv[1]
    targets = sys.argv[2:]
    header = struct.pack("<II", MAGIC, FILE_VER)
    records = []

    if os.path.exists(path) and os.path.getsize(path) >= 8 + REC_SIZE:
        with open(path, "rb") as f:
            data = f.read()
        magic, ver = struct.unpack_from("<II", data, 0)
        if magic == MAGIC and ver == FILE_VER:
            for i in range(8, len(data), REC_SIZE):
                chunk = data[i:i + REC_SIZE]
                if len(chunk) == REC_SIZE:
                    records.append(bytearray(chunk))

    for item in targets:
        pkg, uid_str = item.split(":", 1)
        uid = int(uid_str)
        new_rec = make_profile(pkg, uid)
        for idx, existing in enumerate(records):
            if struct.unpack_from("<i", existing, 0x104)[0] == uid:
                records[idx] = new_rec
                break
        else:
            records.append(new_rec)

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(header + b"".join(records))
    os.chmod(path, 0o600)
    print(f"Saved {len(records)} UAPI v4 records to {path}")

if __name__ == "__main__":
    main()
