/* Freestanding ARM EABI code. Calls use the supported QNX executable's PLT.
 * No Linux libc, QNX structure layout, writable globals or runtime loader.
 * Generated table header contains offsets, value pointers and a CRC32.
 */
#include "aa_volume_table.h"

typedef unsigned int uint;
extern int q_open(const char *, int, ...);
extern int q_close(int);
extern int q_read(int, void *, uint);
extern int q_write(int, const void *, uint);
extern int q_fsync(int);
extern int q_rename(const char *, const char *);
extern void *q_malloc(uint);
extern void q_free(void *);
extern int *q_errno(void);
extern int q_access(const char *, int);

static const char table_path[] = "/net/imx6/tsd/var/audio/audiotable/compiled.dat";
static const char stage_path[] = "/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-new";
static const char failed_path[] = "/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-failed";
static const char xml_path[] = "/net/imx6/tsd/var/audio/audiotable/audiotable.xml";
static const char lock_path[] = "/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-lock";
static const char idle_path[] = "/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-idle";

/* Value pointer word of each slider in the table: 0 Android Auto
 * (INPUTGAINOFFSET_GAL), 1 Apple CarPlay (INPUTGAINOFFSET_DIO). The generated
 * header guarantees AA_VALUE_OFFSET + 4 <= CARPLAY_VALUE_OFFSET.
 */
static const uint value_offsets[2] = {AA_VALUE_OFFSET, CARPLAY_VALUE_OFFSET};

static int known_pointer(uint pointer)
{
    uint i;
    for (i = 0; i < 27; ++i)
        if (aa_value_pointers[i] == pointer)
            return 1;
    return 0;
}

static uint table_crc(const unsigned char *data)
{
    static const uint nibble[16] = {
        0x00000000u, 0x1db71064u, 0x3b6e20c8u, 0x26d930acu,
        0x76dc4190u, 0x6b6b51f4u, 0x4db26158u, 0x5005713cu,
        0xedb88320u, 0xf00f9344u, 0xd6d6a3e8u, 0xcb61b38cu,
        0x9b64c2b0u, 0x86d3d2d4u, 0xa00ae278u, 0xbdbdf21cu,
    };
    uint crc = ~0u, i;
    for (i = 0; i < AA_TABLE_SIZE; ++i) {
        crc ^= data[i];
        crc = (crc >> 4) ^ nibble[crc & 15u];
        crc = (crc >> 4) ^ nibble[crc & 15u];
    }
    return ~crc;
}

int aa_release_lock(void)
{
    return q_rename(lock_path, idle_path);
}

/* QNX fcntl.h: O_WRONLY=000001, O_CREAT=000400, O_EXCL=002000.
 * Reference: github.com/vocho/openqnx, trunk/lib/c/public/fcntl.h.
 * These differ from Linux. O_EXCL also rejects an occupied staging path.
 * errno EINTR=4 and ENOENT=2 are the supported platform's POSIX values.
 */
int aa_save_gain(int slot, int gain)
{
    unsigned char *data = 0;
    int input = -1, stage = -1, rc = 1;
    uint used = 0, pointer, offset, aa_pointer, carplay_pointer, crc;
    int staged = 0, owned = 0;

    if (slot < 0 || slot > 1 || gain < -13 || gain > 13)
        return 1;
    offset = value_offsets[slot];
    if (q_access(xml_path, 0) == 0 || *q_errno() != 2)
        return 1;
    stage = q_open(lock_path, 000001 | 000400 | 002000, 0644);
    if (stage < 0)
        goto done;
    owned = 1;
    if (q_close(stage) != 0) {
        stage = -1;
        goto done;
    }
    stage = -1;
    input = q_open(table_path, 0);
    data = q_malloc(AA_TABLE_SIZE + 1);
    if (input < 0 || !data)
        goto done;
    while (used < AA_TABLE_SIZE + 1) {
        int n = q_read(input, data + used, AA_TABLE_SIZE + 1 - used);
        if (n < 0 && *q_errno() == 4)
            continue;
        if (n < 0)
            goto done;
        if (!n)
            break;
        used += (uint)n;
    }
    if (q_close(input) != 0) {
        input = -1;
        goto done;
    }
    input = -1;
    if (used != AA_TABLE_SIZE)
        goto done;
    aa_pointer = *(uint *)(data + AA_VALUE_OFFSET);
    carplay_pointer = *(uint *)(data + CARPLAY_VALUE_OFFSET);
    if (!known_pointer(aa_pointer) || !known_pointer(carplay_pointer))
        goto done;
    /* Compare the CRC with the mutable pointer words normalized to zero. */
    *(uint *)(data + AA_VALUE_OFFSET) = 0;
    *(uint *)(data + CARPLAY_VALUE_OFFSET) = 0;
    crc = table_crc(data);
    *(uint *)(data + AA_VALUE_OFFSET) = aa_pointer;
    *(uint *)(data + CARPLAY_VALUE_OFFSET) = carplay_pointer;
    if (crc != AA_TABLE_CRC)
        goto done;
    pointer = *(uint *)(data + offset);
    /* A repeated slider value does not rewrite the table payload. */
    if (pointer == aa_value_pointers[gain + 13]) {
        /* A previous post-rename fsync may have failed. Confirm the existing
         * value using a writable descriptor before acknowledging it again.
         * O_WRONLY does not truncate or modify the table.
         */
        stage = q_open(table_path, 000001);
        if (stage < 0 || q_fsync(stage) != 0)
            goto done;
        if (q_close(stage) != 0) {
            stage = -1;
            goto done;
        }
        stage = -1;
        rc = 0;
        goto done;
    }
    *(uint *)(data + offset) = aa_value_pointers[gain + 13];
    stage = q_open(stage_path, 000001 | 000400 | 002000, 0644);
    if (stage < 0)
        goto done;
    staged = 1;
    used = 0;
    while (used < AA_TABLE_SIZE) {
        int n = q_write(stage, data + used, AA_TABLE_SIZE - used);
        if (n < 0 && *q_errno() == 4)
            continue;
        if (n <= 0)
            goto done;
        used += (uint)n;
    }
    if (q_fsync(stage) != 0)
        goto done;
    if (q_rename(stage_path, table_path) != 0)
        goto done;
    staged = 0;
    /* Keep the writable regular-file descriptor open across rename. QNX 6.5
     * fs-qnx6.so documents that fsync explicitly takes a filesystem snapshot,
     * so the second fsync commits the renamed table and its directory entry.
     * Reference: QNX 6.5 Utilities Reference, fs-qnx6.so, snapshot= option.
     * Do not fsync an O_RDONLY directory: the QNX fsync contract requires a
     * writable descriptor. On a post-rename failure durability is unknown;
     * report an error and do not apply the gain in this session.
     */
    if (q_fsync(stage) != 0)
        goto done;
    if (q_close(stage) != 0) {
        stage = -1;
        goto done;
    }
    stage = -1;
    rc = 0;
done:
    if (input >= 0)
        q_close(input);
    if (stage >= 0)
        q_close(stage);
    if (staged)
        q_rename(stage_path, failed_path);
    if (data)
        q_free(data);
    /* Keep ownership through the setter at its original native call site.
     * The assembly continuation releases it after that call returns.
     */
    if (owned && rc != 0)
        aa_release_lock();
    return rc;
}
