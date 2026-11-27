#!/usr/bin/env python3
"""Build the Android Auto and CarPlay GEM patch for supported ARM audiomgr images."""

import hashlib
import functools
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "emmc_extracted/files/net/imx6/tsd/bin/audioservice/tsd.mibstd2.audio.audiomgr"
SOURCE_SHA256 = "a0a4783677d1e55d4f69ef039770fe449ab09cea237e3cb1f4be59c172c05f7b"
TABLE = ROOT / "emmc_extracted/files/net/imx6/tsd/var/audio/audiotable/compiled.dat"
TABLE_SHA256 = "4a30cb96a6038f56a0d46e3790214184f5c9b6e206c8fb0f249cca787a01a10e"
WRITE_CASE = 0x24F300
READ_CASE = 0x2505E0
BT_SELECTOR = 0x24FF90
AFTER_SET = 0x24FFA0
# GEM key 85 (Apple CarPlay): its native write/read dispatch slots.
CARPLAY_KEY = 85
WRITE_CASE_CARPLAY = 0x24F1DC + 4 * (CARPLAY_KEY - 11)
READ_CASE_CARPLAY = 0x250494 + 4 * (CARPLAY_KEY - 1)
CODE_VA = 0x320000
CODE_OFFSET = 0x21A000
PACKAGE = ROOT / "aa_carplay_vol_patch_package"
# P0480T with the MIBSTD2 Toolbox CP patch: J5 runs /tsd/var/tsd.mibstd2.audio.audiomgr,
# the P0480T J5 image audiomgr with 8 bytes patched by Toolbox patch_cp.sh.
# J5 reference: Toolbox J5 root dump 2026-11-19; CP copy: eMMC dump 2026-11-20.
J5_AUDIOMGR = ROOT / "aa_volume_j5_reference/tsd.mibstd2.audio.audiomgr"
J5_AUDIOMGR_SHA256 = "06df158bf54cbbd40d9894658956bbf1d2dfcb94feed1eb4623772a6ad79c4d6"
TB480_SOURCE = ROOT / "Vol_pop_thing/key_files/tsd.mibstd2.audio.audiomgr"
TB480_SHA256 = "899cbd5aa93271af0ec1eb32dbc2c6dfe1cd2732d672f9b2cba3717163dee63d"
# Toolbox patch_cp.sh case 2203579: "bx lr" at both offsets.
TB480_CP = [(0x1618D4, bytes.fromhex("1eff2fe1")), (0x161968, bytes.fromhex("1eff2fe1"))]
# The P0478T i.MX6 copy (SOURCE) differs from J5 at these older CP sites.
P0478T_CP = [(0x1618D4, 4), (0x175D5C, 3)]
TB480_RUNNER_FROM = "exec /net/imx6/tsd/var/aa_volume/tsd.mibstd2.audio.audiomgr.persistent.thin "
# J5 services inherit PATH from the J5 startup script. Set it explicitly so the
# recovery utilities resolve on J5 or, as the J5 startup also allows, i.MX6.
TB480_PATH = ("PATH=/bin:/usr/bin:/sbin:/usr/sbin:/proc/boot:"
              "/net/imx6/bin:/net/imx6/usr/bin:/net/imx6/sbin:/net/imx6/usr/sbin\nexport PATH\n")


# US NAR audiomgr (MST2_US_VW_PQ_P0478T, variant 17220, BuildID 5ba9f00a):
# the same handler code as EU, 0x620 lower; Toolbox CP sites 0x620 lower too.
US_CP_SOURCE = ROOT / "aa_volume_us_reference/tsd.mibstd2.audio.audiomgr.toolbox_cp"
US_CP_SHA256 = "af6202ac4d3a87bc33c49aeabd0c737d0fcc2ae26e1f5d96e0bf89ac897eacda"
US_STOCK_SHA256 = "66abb6bab99affe533be44cace58936e602b25c54b988611fa6cddb105b99cbd"
US_SHIFT = -0x620
US_CP_SITES = (0x1612B4, 0x161348)


def us_sources():
    """US Toolbox-CP audiomgr and its stock J5 form (CP prologues restored)."""
    cp = US_CP_SOURCE.read_bytes()
    if digest(cp) != US_CP_SHA256:
        raise ValueError('Unsupported US audiomgr reference')
    stock = bytearray(cp)
    eu = J5_AUDIOMGR.read_bytes()
    for site in US_CP_SITES:
        if cp[site:site + 4] != bytes.fromhex('1eff2fe1'):
            raise ValueError('US reference lacks the Toolbox CP patch')
        # Original EU prologue at the same function (site - US_SHIFT).
        stock[site:site + 4] = eu[site - US_SHIFT:site - US_SHIFT + 4]
    if digest(bytes(stock)) != US_STOCK_SHA256:
        raise ValueError('Unexpected US stock reconstruction')
    return cp, bytes(stock)


def tb480_source(original):
    """Prove the Toolbox CP audiomgr is the same J5 build as the P0478T source."""
    j5 = J5_AUDIOMGR.read_bytes()
    tb = TB480_SOURCE.read_bytes()
    if digest(j5) != J5_AUDIOMGR_SHA256 or len(j5) != len(original):
        raise ValueError("Unsupported J5 audiomgr reference")
    rebuilt = bytearray(j5)
    for offset, size in P0478T_CP:
        rebuilt[offset:offset + size] = original[offset:offset + size]
    if bytes(rebuilt) != original:
        raise ValueError("P0478T audiomgr differs from J5 beyond its CP sites")
    expected = bytearray(j5)
    for offset, value in TB480_CP:
        if j5[offset:offset + 4] == value:
            raise ValueError("J5 reference already carries the CP patch")
        expected[offset:offset + 4] = value
    if bytes(expected) != tb or digest(tb) != TB480_SHA256:
        raise ValueError("Unsupported Toolbox CP audiomgr")
    return tb


def tb480_runner(text, target):
    if text.count(TB480_RUNNER_FROM) != 1 or text.count("set -eu\n") != 1:
        raise ValueError("Unexpected startup runner template")
    return text.replace(TB480_RUNNER_FROM, target).replace("set -eu\n", "set -eu\n" + TB480_PATH)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def branch(at, target, condition=0xE):
    delta = target - at - 8
    if delta % 4 or not -(1 << 25) <= delta < (1 << 25):
        raise ValueError("ARM branch target out of range")
    return condition << 28 | 0x0A000000 | ((delta // 4) & 0xFFFFFF)


def word(data, va):
    return struct.unpack_from("<I", data, va - 0x100000)[0]


def parse_table(data):
    magic, header, count, string_size, root = struct.unpack_from("<5I", data)
    if magic != 1000234567 or header != 20 or len(data) != header + 4 * count + string_size:
        raise ValueError("Invalid compiled audio table header")
    words = struct.unpack_from(f"<{count}I", data, header)
    strings = data[header + 4 * count:]
    used = set()
    text_words = {}
    nil = 0xFFFFFFFF

    def string(offset):
        return strings[offset:strings.index(0, offset)].decode("utf-8")

    def mark(start, end):
        for i in range(start, end):
            if i in used:
                raise ValueError("Compiled audio table contains overlapping nodes")
            used.add(i)

    def node(index):
        if words[index] != 1:
            raise ValueError("Expected an XML element node")
        next_node, name, child = words[index + 1:index + 4]
        element = ET.Element(string(name))
        i = index + 4
        while words[i] != nil:
            element.set(string(words[i]), string(words[i + 1]))
            i += 2
        mark(index, i + 1)
        while child != nil:
            if words[child] == 0:
                mark(child, child + 3)
                element.text = (element.text or "") + string(words[child + 2])
                text_words[id(element)] = child + 2
                child = words[child + 1]
            else:
                item, child = node(child)
                element.append(item)
        return element, next_node

    document, following = node(root)
    if following != nil or len(used) != count:
        raise ValueError("Compiled audio table contains unreachable or trailing words")
    return document, text_words, strings


def build_persistent_table(original):
    if digest(original) != TABLE_SHA256:
        raise ValueError("Unsupported audio table SHA-256")
    root, text_words, strings = parse_table(original)
    parameter = root.find('./soundsettings[@id="121"]/INPUTGAINOFFSET/parameter[@id="INPUTGAINOFFSET_GAL"]')
    if parameter is None or parameter.findtext("persistent") != "false":
        raise ValueError("Expected the original nonpersistent AA gain parameter")
    flag = parameter.find("persistent")
    offset = 20 + 4 * text_words[id(flag)]
    true_offset = strings.index(b"true\0")
    assert true_offset == 0 or strings[true_offset - 1] == 0
    modified = bytearray(original)
    struct.pack_into("<I", modified, offset, true_offset)
    parameter.find("persistent").text = "true"
    parsed, _, _ = parse_table(modified)
    if ET.tostring(root) != ET.tostring(parsed):
        raise ValueError("Audio table changed beyond the AA persistence flag")
    return bytes(modified), {
        "original_sha256": digest(original),
        "persistent_sha256": digest(modified),
        "changed_pointer_offset": offset,
        "changed_pointer_size": 4,
        "new_pointer_hex": bytes(modified[offset:offset + 4]).hex(),
        "parameter": "INPUTGAINOFFSET_GAL",
        "factory_value": parameter.findtext("value"),
        "persistent": True,
    }


def build_legacy_backend(original, expected_sha256=SOURCE_SHA256, shift=0):
    """SHIFT: offset of the GEM/audio handler code in this audiomgr build
    relative to the EU build (0) - the US NAR build uses -0x620."""
    if digest(original) != expected_sha256:
        raise ValueError("Unsupported audiomgr SHA-256; no output produced")
    WRITE_CASE, READ_CASE, BT_SELECTOR = (globals()['WRITE_CASE'] + shift,
                                          globals()['READ_CASE'] + shift,
                                          globals()['BT_SELECTOR'] + shift)
    S = lambda va: va + shift
    expected = {
        WRITE_CASE: branch(WRITE_CASE, S(0x24F678)),
        READ_CASE: branch(READ_CASE, S(0x250B8C)),
        BT_SELECTOR: 0xE3A02015,  # mov r2, #21 (Bluetooth connection)
    }
    for at, value in expected.items():
        if word(original, at) != value:
            raise ValueError(f"Unexpected instruction at {at:#x}")

    # The new selector is a leaf: no stack changes and no calls outside the
    # original functions' exception/unwind regions. RpcBuffer decoding, the
    # native setter, and acknowledgements stay at their original call sites.
    code = [
        0xE3570054,                          # cmp r7, #84
        0x13A02015,                          # movne r2, #21
        branch(CODE_VA + 8, S(0x24FF94), 0x1),  # bne original BT continuation
        0xE350000D,                          # cmp r0, #13
        branch(CODE_VA + 16, CODE_VA + 36, 0xC),  # bgt reject
        0xE370000D,                          # cmn r0, #13 (lower bound -13)
        branch(CODE_VA + 24, CODE_VA + 36, 0xB),  # blt reject
        0xE3A0209C,                          # mov r2, #156 (AA music)
        branch(CODE_VA + 32, S(0x24FF94)),
        0xE3A03008,                          # reject: native GEM error 8
        branch(CODE_VA + 40, S(0x24F6E0)),
        0xE3A0209C,                          # read: mov r2, #156
        branch(CODE_VA + 48, S(0x250D20)),      # native input gain getter
    ]
    appended = struct.pack(f"<{len(code)}I", *code)
    patched = bytearray(original)
    replacements = {
        WRITE_CASE: branch(WRITE_CASE, S(0x24FF84)),  # share native BT decoder
        READ_CASE: branch(READ_CASE, CODE_VA + 44),
        BT_SELECTOR: branch(BT_SELECTOR, CODE_VA),
    }
    for at, value in replacements.items():
        struct.pack_into("<I", patched, at - 0x100000, value)

    # Reuse only the GNU build-id PT_NOTE slot. Keep the QNX stack note,
    # existing LOADs, interpreter, dynamic data, section table, and entry point.
    phoff = struct.unpack_from("<I", original, 28)[0]
    note_offset = phoff + 7 * 32
    note = struct.unpack_from("<8I", original, note_offset)
    assert note[0] == 4 and note[2:] == (0x100160, 0, 0x24, 0x24, 4, 4), note
    assert max(p[2] + p[5] for p in (struct.unpack_from("<8I", original, phoff + 32 * n)
                                     for n in range(8)) if p[0] == 1) <= CODE_VA
    assert len(original) < CODE_OFFSET
    struct.pack_into("<8I", patched, note_offset,
                     1, CODE_OFFSET, CODE_VA, 0, len(appended), len(appended), 5, 4096)
    patched.extend(bytes(CODE_OFFSET - len(patched)))
    patched.extend(appended)
    manifest = {
        "original_sha256": digest(original),
        "patched_sha256": digest(patched),
        "original_size": len(original),
        "patched_size": len(patched),
        "namespace": "0x01a900d8",
        "new_key": 84,
        "aa_connection": 156,
        "parameter_type": 29,
        "limits": [-13, 13],
        "write_case_va": hex(WRITE_CASE),
        "read_case_va": hex(READ_CASE),
        "bt_selector_va": hex(BT_SELECTOR),
        "code_va": hex(CODE_VA),
        "code_file_offset": hex(CODE_OFFSET),
        "code_size": len(appended),
        "changed_original_file_regions": [
            [note_offset, 32],
            *[[va - 0x100000, 4] for va in replacements],
        ],
        "persistence": "AA persistence flag enabled. The native fixed profile omits AA.",
    }
    return bytes(patched), manifest


def build_boot_table(original):
    """Keep XML semantics; supply missing numeric strings for atomic value edits."""
    table, legacy = build_persistent_table(original)
    root, words, strings = parse_table(table)
    value = root.find('./soundsettings[@id="121"]/INPUTGAINOFFSET/parameter[@id="INPUTGAINOFFSET_GAL"]/value')
    value_offset = 20 + 4 * words[id(value)]
    carplay = root.find('./soundsettings[@id="121"]/INPUTGAINOFFSET/parameter[@id="INPUTGAINOFFSET_DIO"]')
    if carplay is None or carplay.findtext('persistent') != 'false':
        raise ValueError('Expected the original CarPlay (DIO) gain parameter')
    carplay_value_offset = 20 + 4 * words[id(carplay.find('value'))]
    if carplay_value_offset < value_offset + 4:
        raise ValueError('Unexpected AA/CarPlay value order')
    pool = bytearray(strings)
    pointers = []
    for gain in range(-13, 14):
        text = str(gain).encode() + b'\0'
        offset = next((i for i in range(len(pool))
                       if pool.startswith(text, i) and (i == 0 or pool[i - 1] == 0)), None)
        if offset is None:
            offset = len(pool)
            pool.extend(text)
        pointers.append(offset)
    output = bytearray(table[:len(table) - len(strings)]) + pool
    struct.pack_into('<I', output, 12, len(pool))
    parsed, _, _ = parse_table(output)
    if ET.tostring(root) != ET.tostring(parsed):
        raise ValueError('Boot table changed XML beyond the legacy AA flag')
    return bytes(output), dict(legacy, persistent_sha256=digest(output),
                               value_offset=value_offset, value_pointers=pointers,
                               carplay_value_offset=carplay_value_offset,
                               carplay_factory_value=carplay.findtext('value'),
                               size=len(output), legacy_table_sha256=digest(table))


PERSIST_PLT = {
    'q_open': 0x123b14, 'q_close': 0x124318,
    'q_read': 0x123fc4, 'q_write': 0x12427c,
    'q_fsync': 0x12499c, 'q_rename': 0x1247f8,
    'q_malloc': 0x123d84, 'q_free': 0x12490c,
    'q_memcmp': 0x124648, 'q_errno': 0x123dd8, 'q_access': 0x124090,
}


def normalized_table(table, metadata):
    output = bytearray(table)
    for field in ('value_offset', 'carplay_value_offset'):
        struct.pack_into('<I', output, metadata[field], 0)
    return bytes(output)


@functools.lru_cache(maxsize=None)
def persistence_code(shift=0):
    table, metadata = build_boot_table(TABLE.read_bytes())
    with tempfile.TemporaryDirectory(prefix='aa-persist-build-') as folder:
        work = Path(folder)
        (work / 'aa_volume_table.h').write_text(
            f'#define AA_TABLE_SIZE {len(table)}u\n'
            f'#define AA_TABLE_CRC 0x{zlib.crc32(normalized_table(table, metadata)):08x}u\n'
            f'#define AA_VALUE_OFFSET {metadata["value_offset"]}u\n'
            f'#define CARPLAY_VALUE_OFFSET {metadata["carplay_value_offset"]}u\n'
            'static const unsigned int aa_value_pointers[27] = {' +
            ','.join(str(p) for p in metadata['value_pointers']) + '};\n')
        for source, output in [('aa_volume_persist.c', 'persist.o'), ('aa_volume_entry.S', 'entry.o')]:
            subprocess.run(['arm-linux-gnueabi-gcc', '-c', '-Os', '-marm', '-march=armv7-a',
                            '-mfloat-abi=soft', '-fno-pic', '-fno-pie', '-fno-stack-protector',
                            '-fno-unwind-tables', '-fno-asynchronous-unwind-tables',
                            '-ffreestanding', '-fno-builtin', '-I', str(work),
                            str(ROOT / source), '-o', str(work / output)], check=True)
        script = ('SECTIONS { . = 0x320000; .text : { *(.text.entry) *(.text*) } '
                  '.rodata : { *(.rodata*) } .data : { *(.data*) } .bss : { *(.bss*) } '
                  'ASSERT(SIZEOF(.data) == 0 && SIZEOF(.bss) == 0, "Writable state forbidden") }\n')
        script += ''.join(f'{name} = {address:#x};\n' for name, address in PERSIST_PLT.items())
        script += (f'aa_bt_continue = {0x24FF94 + shift:#x};\n'
                   f'aa_gem_finish = {0x24F6E0 + shift:#x};\n'
                   f'aa_gain_getter = {0x250D20 + shift:#x};\n')
        (work / 'payload.ld').write_text(script)
        subprocess.run(['arm-linux-gnueabi-ld', '-T', str(work / 'payload.ld'),
                        str(work / 'entry.o'), str(work / 'persist.o'),
                        '-o', str(work / 'payload.elf')], check=True)
        subprocess.run(['arm-linux-gnueabi-objcopy', '-O', 'binary', str(work / 'payload.elf'),
                        str(work / 'payload.bin')], check=True)
        symbols = {}
        for line in subprocess.check_output(['arm-linux-gnueabi-nm', str(work / 'payload.elf')], text=True).splitlines():
            address, kind, name = line.split()
            symbols[name] = int(address, 16)
        return (work / 'payload.bin').read_bytes(), symbols


def build_backend(original, expected_sha256=SOURCE_SHA256, install_target=
                  '/net/imx6/tsd/var/aa_volume/tsd.mibstd2.audio.audiomgr.persistent.thin', shift=0):
    legacy, manifest = build_legacy_backend(original, expected_sha256, shift)
    appended, symbols = persistence_code(shift)
    READ_CASE, AFTER_SET = globals()['READ_CASE'] + shift, globals()['AFTER_SET'] + shift
    WRITE_CASE_CARPLAY = globals()['WRITE_CASE_CARPLAY'] + shift
    READ_CASE_CARPLAY = globals()['READ_CASE_CARPLAY'] + shift
    patched = bytearray(legacy[:CODE_OFFSET]) + appended
    struct.pack_into('<I', patched, READ_CASE - 0x100000,
                     branch(READ_CASE, symbols['aa_read']))
    # Key 85 shares key 84's path: native BT decoder, then the AA selector.
    # Both of its slots must still be the unused-key defaults, as 84's were.
    if (word(original, WRITE_CASE_CARPLAY) != branch(WRITE_CASE_CARPLAY, 0x24F678 + shift)
            or word(original, READ_CASE_CARPLAY) != branch(READ_CASE_CARPLAY, 0x250B8C + shift)):
        raise ValueError('GEM key 85 is already handled natively')
    struct.pack_into('<I', patched, WRITE_CASE_CARPLAY - 0x100000,
                     branch(WRITE_CASE_CARPLAY, 0x24FF84 + shift))
    struct.pack_into('<I', patched, READ_CASE_CARPLAY - 0x100000,
                     branch(READ_CASE_CARPLAY, symbols['aa_read_carplay']))
    manifest['changed_original_file_regions'] += [[WRITE_CASE_CARPLAY - 0x100000, 4],
                                                  [READ_CASE_CARPLAY - 0x100000, 4]]
    if word(original, AFTER_SET) != 0xE3A03000:
        raise ValueError('Unexpected native setter continuation')
    struct.pack_into('<I', patched, AFTER_SET - 0x100000,
                     branch(AFTER_SET, symbols['aa_after_set']))
    manifest['changed_original_file_regions'].append([AFTER_SET - 0x100000, 4])
    note_offset = manifest['changed_original_file_regions'][0][0]
    struct.pack_into('<8I', patched, note_offset,
                     1, CODE_OFFSET, CODE_VA, 0, len(appended), len(appended), 5, 4096)
    manifest.update(patched_sha256=digest(patched), patched_size=len(patched),
                    code_size=len(appended), save_gain_va=hex(symbols['aa_save_gain']),
                    release_lock_va=hex(symbols['aa_release_lock']),
                    persistence='Atomic INPUTGAINOFFSET_GAL/value (key 84, AA) or INPUTGAINOFFSET_DIO/value (key 85, CarPlay) update in compiled.dat; native table loader restores on boot.',
                    carplay_key=CARPLAY_KEY, carplay_connection=162,
                    sync_policy='QNX6 snapshot via fsync on the same writable regular-file descriptor before and after rename; never fsync a directory.',
                    install_target=install_target,
                    legacy_backend_sha256=digest(legacy),
                    persistence_plt={k: hex(v) for k, v in PERSIST_PLT.items()},
                    handler_shift=hex(shift))
    return bytes(patched), manifest


def image_parts(image, base):
    """Encode IMAGE as BASE with byte runs replaced plus an appended tail."""
    if len(image) < len(base):
        raise ValueError('Image shorter than its base')
    regions, data, start = [], bytearray(), None
    for i in range(len(base) + 1):
        differs = i < len(base) and image[i] != base[i]
        if differs and start is None:
            start = i
        elif not differs and start is not None:
            regions.append((start, i - start))
            data += image[start:i]
            start = None
    return regions, bytes(data), image[len(base):]


def fingerprint(data):
    return struct.pack('<II', zlib.crc32(data), len(data)).hex() + ' ' + digest(data) + '\n'


def write_check(path, data):
    path.write_text(fingerprint(data), encoding='ascii')


def write_delta(folder, name, stock, patched):
    regions, replacement, tail = image_parts(patched, stock)
    (folder / f'{name}.regions').write_text(''.join(
        f'{offset} {length} {stock[offset:offset + length].hex()}\n'
        for offset, length in regions), encoding='ascii')
    (folder / f'{name}.bytes').write_bytes(replacement)
    (folder / f'{name}.tail').write_bytes(tail)
    write_check(folder / f'{name}.check', patched)


# Fingerprints from the released full-image package. Install keeps the old
# executable on disk and selects the new one by changing the runner atomically.
PREVIOUS_DUAL = {
    '478': ('cacc2654d8b32300 bc1ce0bc17d1f377b6fe1507b1ac13b2305d77c298747931f44ab690445d2b8f',
            '8fbc9b57a6050000 0496e9fa0340f3729e947b7d1af19f1bbd1c06b4aad0e466401ec9686d5dff6d'),
    'p480': ('81a6e4ddd8b32300 be4e9126fd4904e17869e56c33faffa91f68836c5dd449e924048e37e84508cd',
             '92ee4ea01c060000 94c1c07f2388e0eac4db0663879e2abd059cf0056e4d63cfc0d5b7d28e27e89c'),
    'tb480': ('0b5a0ba7d8b32300 9ed08ab4be624389d6d4a31ca08242d085a8b8d88ae07f81a54233a1f366d649',
              'f78d30b41d060000 16872c22e5c316df6cc7d7a374201eee03e7493475975f34f32a665a07473434'),
    'tbus': ('7b63d081d8b32300 7c9ec6f549a1ad5abf30fc260fcebb69474c109785030b900e075c3f48ee3343',
             '0f9fa7481c060000 dc5e7d1fc298c3b7a5d821e7f17930d9f8281a07e955eb010384eb18c7657c27'),
    'pus': ('4ebd9729d8b32300 d86dea7568b22a9c437c34a04b48a5e9eeda39c2eb782a25f1515ad632486396',
            '13b598371b060000 1ce0f56b842231abe20410a72a2475350886986a66cf0dc5eb4e141eada111db'),
}


# Fingerprints from the earlier Android Auto-only releases and the J5 hook.
PREVIOUS_AA_ONLY = {
    '478': ('1b2cecc654b32300 2b79f6a06d1a6eb126145fb723c8c2ace88ea65fa051f0b1f0dc55e497df897f',
            'f3c7e95aa7050000 813485b2b74266a5de9750c7d273db835e3ea747a77c5e2a0881e77f0d8c7f61'),
    'p480': ('0f29e40c54b32300 b8fa19044fc44cf6611302e1ea016fadc78293c4a1762dda410898ea179fa4b0',
             '2d257ae717060000 5ce6afadfda0f9bbeed905bfd91aefccf0eb06950e937cfeb7cd14d17141fd02'),
    'tb480': ('f5acccb054b32300 1e724c7702d4dfeb07cf1784b2a8cf5155b6314375f54096e8006685769eb20a',
              '3a54f14118060000 0c0ea41f69d2a6c0f38f71e53529103e6dbacd0c9454bdae7d4ee75b317440d2'),
}
BEFORE_FSYNC = '04ab3bb8d4b32300 8518a45baf9ba76b0c58410d46c5873d2859a8043e267bf89a84dda1f666d101'
BEFORE_FSYNC_RUNNERS = (
    '0752fabea1050000 4b5b789fc00ce06f1a4bdd18b2d5b7136d837d759a50855bdf3c0b3b1e264746',
    'da1074c763030000 afe1587f14d36df7d3a41e98007c4c2db3bd1bf10ca2377f63f945f696748b9c',
)

J5_CONF_FINGERPRINT = '3654aec8e1100000 fc6b4ee81f807cdac276be320ef3b3e35547661eddf27a94f1005d05d986e496'
OLD_J5_HOOK_FINGERPRINT = '6bdea1a000030000 2a1e4c26b8cb88b8f77c5e1c99432dfde0c65e5819f533f70464940e85646882'


def write_previous_checks(folder, layout, target):
    dual, runner = PREVIOUS_DUAL[layout]
    (folder / 'dual.check').write_text(dual + '\n', encoding='ascii')
    backends = [(target.rsplit('.', 1)[0] + '.dual', 'dual')]
    runners = [runner + '\n']
    if layout in PREVIOUS_AA_ONLY:
        backend, old_runner = PREVIOUS_AA_ONLY[layout]
        (folder / 'aa_only.check').write_text(backend + '\n', encoding='ascii')
        name = 'persistent.fsync' if layout == '478' else layout
        backends.append((f'tsd.mibstd2.audio.audiomgr.{name}', 'aa_only'))
        runners.append(old_runner + '\n')
    if layout == '478':
        (folder / 'before_fsync.check').write_text(BEFORE_FSYNC + '\n', encoding='ascii')
        backends.append(('tsd.mibstd2.audio.audiomgr.persistent', 'before_fsync'))
        runners.extend(fingerprint + '\n' for fingerprint in BEFORE_FSYNC_RUNNERS)
    (folder / 'previous_backends.txt').write_text(''.join(
        f'{name} {check}\n' for name, check in backends), encoding='ascii')
    (folder / 'previous_runners.txt').write_text(''.join(runners), encoding='ascii')


J5_HOOK = '''# AA / CarPlay volume patch startup hook, by lols11.
export TSD_COMMON_CONFIG=/tsd/etc/system/tsd.mibstd2.main.root.conf
export TSD_LOGCHANNEL=J5e
(
    on -p 20 /tsd/bin/root/tsd.mibstd2.main.root -file=/tsd/var/main.conf -swdlfile=/tsd/etc/system/swdl/main_swdl.conf -reset=/net/imx6/tsd/var/root/reset.count.main
    case $? in
        0) . /tsd/bin/system/shutdown ;;
        42) echo 'Boot stopped (MP42)' ;;
    esac
) &
'''


def build_package():
    original = SOURCE.read_bytes()
    j5 = J5_AUDIOMGR.read_bytes()
    tb = tb480_source(original)
    us_cp, us_stock = us_sources()
    original_table = TABLE.read_bytes()
    persistent_table, table = build_boot_table(original_table)

    custom = PACKAGE / 'custom'
    scripts = custom / 'greenmenu/scripts'
    data = scripts / 'aa_volume_data'
    if data.is_dir():
        shutil.rmtree(data)  # generated content only
    data.mkdir(parents=True)
    (data / 'j5_hook.sh').write_text(J5_HOOK, encoding='ascii')
    write_check(data / 'j5_hook.check', J5_HOOK.encode('ascii'))
    (data / 'old_j5_hook.check').write_text(OLD_J5_HOOK_FINGERPRINT + '\n', encoding='ascii')
    (data / 'j5_conf.check').write_text(J5_CONF_FINGERPRINT + '\n', encoding='ascii')
    write_check(data / 'legacy.check', build_legacy_backend(original)[0])

    table_dir = data / 'table'
    table_dir.mkdir()
    write_check(table_dir / 'stock.check', original_table)
    write_check(table_dir / 'legacy.check', build_persistent_table(original_table)[0])
    write_delta(table_dir, 'persistent', original_table, persistent_table)
    write_check(table_dir / 'normalized.check', normalized_table(persistent_table, table))
    (table_dir / 'zero.bin').write_bytes(bytes(4))
    (table_dir / 'values.txt').write_text(
        f'{table["value_offset"]} {table["size"]} {table["carplay_value_offset"]}\n' +
        ''.join(struct.pack('<I', p).hex() + '\n' for p in table['value_pointers']),
        encoding='ascii',
    )

    runner = (ROOT / 'aa_volume_start.sh').read_text()
    for layout, stock, expected, shift, suffix in (
        ('478', original, SOURCE_SHA256, 0, 'persistent'),
        ('p480', j5, J5_AUDIOMGR_SHA256, 0, 'p480'),
        ('tb480', tb, TB480_SHA256, 0, 'tb480'),
        ('pus', us_stock, US_STOCK_SHA256, US_SHIFT, 'pus'),
        ('tbus', us_cp, US_CP_SHA256, US_SHIFT, 'tbus'),
    ):
        folder = data if layout == '478' else data / layout
        folder.mkdir(exist_ok=True)
        target = f'tsd.mibstd2.audio.audiomgr.{suffix}.thin'
        target_path = '/net/imx6/tsd/var/aa_volume/' + target
        backend, _ = build_backend(stock, expected, target_path, shift)
        write_check(folder / 'stock.check', stock)
        write_delta(folder, 'backend', stock, backend)
        layout_runner = runner if layout == '478' else tb480_runner(runner, f'exec {target_path} ')
        (folder / 'start.sh').write_text(layout_runner, encoding='ascii')
        write_check(folder / 'start.check', layout_runner.encode('ascii'))
        write_previous_checks(folder, layout, target)

    esd = scripts.parent / 'aa_carplay_vol_patch.esd'
    shutil.copyfile(ROOT / esd.name, esd)
    legacy_esd = scripts.parent / 'aa_volume.esd'
    legacy_esd.write_text('# Superseded by aa_carplay_vol_patch.esd.\n', encoding='ascii')
    installer = scripts / 'aa_carplay_vol_patch.sh'
    shutil.copyfile(ROOT / installer.name, installer)
    package_files = [esd, legacy_esd, installer]
    for action in ('install', 'status', 'uninstall'):
        wrapper = scripts / f'aa_carplay_vol_patch_{action}.sh'
        wrapper.write_text('#!/bin/ksh\nksh /tsd/etc/persistence/esd/scripts/aa_carplay_vol_patch.sh '
                           + action + '\n', encoding='ascii')
        package_files.append(wrapper)

    old_readme = custom / 'README.md'
    if old_readme.is_file():
        old_readme.unlink()
    readme = PACKAGE / 'README.md'
    readme.write_text(
        '# MST2 AA / CarPlay Volume Patch 1.1\n\n'
        'Free for all by lols11.\n\n'
        '[Installation, updates and source code](https://github.com/lols11/mst2_aa_carplay_vol_patch).\n',
        encoding='utf-8',
    )
    package_files.append(readme)
    package_files.extend(path for path in data.rglob('*') if path.is_file())
    archive = ROOT / 'aa_carplay_vol_patch.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for path in sorted(package_files):
            info = zipfile.ZipInfo(path.relative_to(PACKAGE).as_posix(), (2026, 11, 4, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if path.suffix == '.sh' else 0o100644) << 16
            z.writestr(info, path.read_bytes())
    print(f'Package: {archive}')


if __name__ == '__main__':
    build_package()
